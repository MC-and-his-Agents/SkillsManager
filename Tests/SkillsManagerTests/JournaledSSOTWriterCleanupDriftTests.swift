import Foundation
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT writer cleanup drift")
struct JournaledSSOTWriterCleanupDriftTests {
    enum NonCleanupFailure: CaseIterable, Sendable {
        case databaseDrift
        case finalDrift
        case attemptLimit
        case debtMismatch

        var errorCode: SSOTRecoveryErrorCode {
            switch self {
            case .databaseDrift, .finalDrift: .replaceStateMismatch
            case .attemptLimit: .attemptLimitExceeded
            case .debtMismatch: .cleanupDebtMismatch
            }
        }
    }

    @Test("applied cleanup debt drift persists a terminal repair blocker")
    func appliedDebtDriftNeedsRepair() async throws {
        let workspace = try WriterWorkspace()
        var writer: JournaledSSOTWriter? = try await workspace.openWriter()
        let skillID = SkillID()
        let oldSnapshot = try workspace.snapshot(content: "old")
        let old = try await writer!.create(
            payload: try workspace.payload(skillID: skillID, name: "Old", snapshot: oldSnapshot),
            sourceSnapshot: oldSnapshot
        )
        writer = nil

        var hooks = JournaledSSOTWriterHooks()
        hooks.shouldFailCleanup = { $0 == .recovery }
        writer = try await workspace.openWriter(hooks: hooks)
        let newSnapshot = try workspace.snapshot(content: "new")
        let operation = try await writer!.replace(
            payload: try workspace.payload(skillID: skillID, name: "New", snapshot: newSnapshot),
            sourceSnapshot: newSnapshot,
            expectedOld: try SSOTReplacementExpectation(
                identity: old.expectedNewIdentity,
                fingerprint: old.newFingerprint,
                databaseRevision: 0
            )
        )
        #expect(operation.state.cleanupState == .pending)
        writer = nil
        try tamperOperationItem(operation.operationID.uuid, workspace: workspace)

        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await workspace.openWriter()
        }
        try expectRepairState(workspace, outcome: "applied")
        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await workspace.openWriter()
        }
    }

    @Test("rolled-back cleanup debt drift persists a terminal repair blocker")
    func rolledBackDebtDriftNeedsRepair() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.shouldFailCleanup = { $0 == .staging }
        hooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "rollback")
        try await performCancelledCreate(
            writer: writer!,
            workspace: workspace,
            snapshot: snapshot
        )
        #expect(try workspace.scalar("SELECT cleanup_state FROM skill_operations") == "pending")
        let operationID = try workspace.operationID(type: .create)
        writer = nil
        try tamperOperationItem(operationID, workspace: workspace)

        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await workspace.openWriter()
        }
        try expectRepairState(workspace, outcome: "rolledBack")
        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await workspace.openWriter()
        }
    }

    @Test(
        "non-cleanup failures preserve their code and do not become cleanup identity drift",
        arguments: NonCleanupFailure.allCases
    )
    func nonCleanupFailuresStayPending(_ failure: NonCleanupFailure) async throws {
        let workspace = try WriterWorkspace()
        var writer: JournaledSSOTWriter? = try await workspace.openWriter()
        let skillID = SkillID()
        let oldSnapshot = try workspace.snapshot(content: "old")
        let old = try await writer!.create(
            payload: try workspace.payload(skillID: skillID, name: "Old", snapshot: oldSnapshot),
            sourceSnapshot: oldSnapshot
        )
        writer = nil

        var hooks = JournaledSSOTWriterHooks()
        hooks.shouldFailCleanup = { $0 == .recovery }
        writer = try await workspace.openWriter(hooks: hooks)
        let newSnapshot = try workspace.snapshot(content: "new")
        let operation = try await writer!.replace(
            payload: try workspace.payload(skillID: skillID, name: "New", snapshot: newSnapshot),
            sourceSnapshot: newSnapshot,
            expectedOld: try SSOTReplacementExpectation(
                identity: old.expectedNewIdentity,
                fingerprint: old.newFingerprint,
                databaseRevision: 0
            )
        )
        try introduce(failure, operation: operation, skillID: skillID, workspace: workspace)

        do {
            try await writer!.recoverAll()
            Issue.record("Expected recovery to fail closed")
        } catch let error as JournaledSSOTWriterError {
            #expect(error == .operationNeedsRepair(operation.operationID, failure.errorCode))
        }
        #expect(try workspace.scalar(
            "SELECT cleanup_state FROM skill_operations WHERE operation_type = 'replace'"
        ) == "pending")
        #expect(try workspace.scalar(
            "SELECT outcome FROM skill_operations WHERE operation_type = 'replace'"
        ) == "applied")
    }

    private func tamperOperationItem(_ operationID: UUID, workspace: WriterWorkspace) throws {
        let directory = workspace.root.appendingPathComponent(
            ".skillsmanager-tmp-\(operationID.uuidString.lowercased())"
        )
        try Data("externally changed".utf8).write(
            to: directory.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
    }

    private func introduce(
        _ failure: NonCleanupFailure,
        operation: SSOTJournalRecord,
        skillID: SkillID,
        workspace: WriterWorkspace
    ) throws {
        switch failure {
        case .databaseDrift:
            try workspace.execute("UPDATE skills SET display_name = 'Externally changed'")
        case .finalDrift:
            try Data("externally changed".utf8).write(
                to: workspace.root
                    .appendingPathComponent(skillID.directoryName)
                    .appendingPathComponent("SKILL.md"),
                options: .atomic
            )
        case .attemptLimit:
            try workspace.mutateIgnoringTrigger(
                named: "skill_operations_lifecycle",
                "UPDATE skill_operations SET attempt_count = 10001 "
                    + "WHERE operation_type = 'replace'"
            )
        case .debtMismatch:
            try workspace.mutateIgnoringTrigger(
                named: "cleanup_debts_immutable_ownership",
                "UPDATE cleanup_debts SET expected_content_fingerprint = zeroblob(32)"
            )
        }
    }

    private func expectRepairState(
        _ workspace: WriterWorkspace,
        outcome: String
    ) throws {
        let operationType = outcome == "applied" ? "replace" : "create"
        let suffix = " WHERE operation_type = '\(operationType)'"
        #expect(try workspace.scalar("SELECT phase FROM skill_operations" + suffix) == "completed")
        #expect(try workspace.scalar("SELECT outcome FROM skill_operations" + suffix) == outcome)
        #expect(try workspace.scalar("SELECT cleanup_state FROM skill_operations" + suffix) == "needsRepair")
        #expect(try workspace.integer("SELECT count(*) FROM cleanup_debts") == 1)
    }

    private func performCancelledCreate(
        writer: JournaledSSOTWriter,
        workspace: WriterWorkspace,
        snapshot: SkillContentSnapshot
    ) async throws {
        let payload = try workspace.payload(name: "Rollback", snapshot: snapshot)
        let write = Task {
            try await writer.create(payload: payload, sourceSnapshot: snapshot)
        }
        await #expect(throws: CancellationError.self) { _ = try await write.value }
    }
}
