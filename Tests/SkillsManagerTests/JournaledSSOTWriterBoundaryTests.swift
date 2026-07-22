import Foundation
import Synchronization
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT writer recovery boundaries")
struct JournaledSSOTWriterBoundaryTests {
    private enum Stop: Error { case requested }

    enum CorruptJournalField: CaseIterable, Sendable {
        case payload
        case stagedIdentity
    }

    @Test(
        "replacement swap boundaries restore durability and converge",
        arguments: [
            SSOTOperationFileSystemCheckpoint.afterReplacementSwapBeforeParentSync,
            .afterReplacementParentSyncBeforeValidation,
        ]
    )
    func recoversReplacementFileSystemBoundary(
        point: SSOTOperationFileSystemCheckpoint
    ) async throws {
        let context = try await replacementContext()
        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.fileSystemCheckpoint = { reached in
            guard reached == point else { return }
            let shouldStop = fired.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if shouldStop { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await context.workspace.openWriter(hooks: hooks)
        do {
            _ = try await replace(context, writer: writer!)
            Issue.record("Expected filesystem checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let recovered = try await context.workspace.openWriter()
        _ = recovered
        #expect(try context.workspace.scalar("SELECT display_name FROM skills") == "New")
        #expect(try context.workspace.integer("SELECT db_revision FROM skills") == 1)
        #expect(try context.workspace.internalItemCount() == 0)
    }

    @Test("cleanup interruption before removal retries safely")
    func retriesCleanupBeforeRemoval() async throws {
        let context = try await replacementContext()
        var hooks = JournaledSSOTWriterHooks()
        hooks.fileSystemCheckpoint = { point in
            if point == .beforeCleanupRemoval { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await context.workspace.openWriter(hooks: hooks)
        do {
            _ = try await replace(context, writer: writer!)
            Issue.record("Expected cleanup checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let recovered = try await context.workspace.openWriter()
        _ = recovered
        #expect(try context.workspace.scalar("SELECT display_name FROM skills") == "New")
        #expect(try context.workspace.scalar(
            "SELECT cleanup_state FROM skill_operations WHERE operation_type = 'replace'"
        ) == "completed")
    }

    @Test(
        "cleanup interruption after removal is explicitly repair-blocking",
        arguments: [
            SSOTOperationFileSystemCheckpoint.afterCleanupRemovalBeforeParentSync,
            .afterCleanupParentSyncBeforeValidation,
        ]
    )
    func cleanupAfterRemovalNeedsRepair(
        point: SSOTOperationFileSystemCheckpoint
    ) async throws {
        let context = try await replacementContext()
        var hooks = JournaledSSOTWriterHooks()
        hooks.fileSystemCheckpoint = { reached in
            if reached == point { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await context.workspace.openWriter(hooks: hooks)
        do {
            _ = try await replace(context, writer: writer!)
            Issue.record("Expected cleanup checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await context.workspace.openWriter()
        }
        #expect(try context.workspace.scalar(
            "SELECT outcome FROM skill_operations WHERE operation_type = 'replace'"
        ) == "needsRepair")
        #expect(try context.workspace.scalar("SELECT display_name FROM skills") == "New")
    }

    @Test("database-committed cleanup debt removes recovery and converges atomically")
    func databaseCommittedCleanupDebtConverges() async throws {
        let context = try await replacementContext()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterDomainTransaction { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await context.workspace.openWriter(hooks: hooks)
        do {
            _ = try await replace(context, writer: writer!)
            Issue.record("Expected domain checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let operationID = try context.workspace.operationID(type: .replace)
        _ = try context.workspace.bindPendingRecoveryDebt(operationID: operationID)

        writer = try await context.workspace.openWriter()
        #expect(try context.workspace.scalar(
            "SELECT phase FROM skill_operations WHERE operation_type = 'replace'"
        ) == "completed")
        #expect(try context.workspace.scalar(
            "SELECT outcome FROM skill_operations WHERE operation_type = 'replace'"
        ) == "applied")
        #expect(try context.workspace.scalar(
            "SELECT cleanup_state FROM skill_operations WHERE operation_type = 'replace'"
        ) == "completed")
        #expect(try context.workspace.integer("SELECT count(*) FROM cleanup_debts") == 0)
        writer = nil

        let reopened = try await context.workspace.openWriter()
        try await reopened.recoverAll()
    }

    @Test("database-committed cleanup debt with missing recovery stays repair-blocking")
    func missingDatabaseCommittedRecoveryNeedsRepair() async throws {
        let context = try await replacementContext()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterDomainTransaction { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await context.workspace.openWriter(hooks: hooks)
        do {
            _ = try await replace(context, writer: writer!)
            Issue.record("Expected domain checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let operationID = try context.workspace.operationID(type: .replace)
        _ = try context.workspace.bindPendingRecoveryDebt(operationID: operationID)
        try context.workspace.removeOperationItem(operationID)

        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await context.workspace.openWriter()
        }
        #expect(try context.workspace.scalar(
            "SELECT phase FROM skill_operations WHERE operation_type = 'replace'"
        ) == "databaseCommitted")
        #expect(try context.workspace.scalar(
            "SELECT outcome FROM skill_operations WHERE operation_type = 'replace'"
        ) == "needsRepair")
        #expect(try context.workspace.scalar(
            "SELECT cleanup_state FROM skill_operations WHERE operation_type = 'replace'"
        ) == "pending")
        #expect(try context.workspace.integer("SELECT count(*) FROM cleanup_debts") == 1)
        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await context.workspace.openWriter()
        }
    }

    @Test("interruption after staging leaves an unowned orphan and no journal")
    func preservesPreJournalOrphan() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterStaging { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "orphan")
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(name: "Orphan", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
            Issue.record("Expected staging interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        #expect(try workspace.integer("SELECT count(*) FROM skill_operations") == 0)
        #expect(try workspace.internalItemCount() == 1)
        writer = nil

        let reopened = try await workspace.openWriter()
        _ = reopened
        #expect(try workspace.integer("SELECT count(*) FROM skill_operations") == 0)
        #expect(try workspace.internalItemCount() == 1)
    }

    @Test("source uniqueness conflict is stable needs-repair")
    func sourceConflictNeedsRepair() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let first = try workspace.snapshot(content: "first")
        _ = try await writer.create(
            payload: try workspace.payload(
                name: "First",
                snapshot: first,
                sourceKey: "skills/shared"
            ),
            sourceSnapshot: first
        )
        let second = try workspace.snapshot(content: "second")
        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await writer.create(
                payload: try workspace.payload(
                    name: "Second",
                    snapshot: second,
                    sourceKey: "skills/shared"
                ),
                sourceSnapshot: second
            )
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer(
            "SELECT count(*) FROM skill_operations WHERE outcome = 'needsRepair'"
        ) == 1)
    }

    @Test("stale replacement revision does not swap the final directory")
    func staleRevisionNeedsRepairBeforeSwap() async throws {
        let context = try await replacementContext()
        try context.workspace.execute("UPDATE skills SET db_revision = 9")
        let writer = try await context.workspace.openWriter()
        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await replace(context, writer: writer)
        }
        #expect(try context.workspace.scalar("SELECT display_name FROM skills") == "Old")
        #expect(try context.workspace.integer("SELECT db_revision FROM skills") == 9)
        #expect(try context.workspace.integer(
            "SELECT count(*) FROM skill_operations WHERE operation_type = 'replace' AND outcome = 'needsRepair'"
        ) == 1)
    }

    @Test("repeated recovery is idempotent")
    func repeatedRecoveryHasNoSideEffects() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "idempotent")
        _ = try await writer.create(
            payload: try workspace.payload(name: "Idempotent", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        try await writer.recoverAll()
        try await writer.recoverAll()
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.integer("SELECT count(*) FROM skill_operations") == 1)
        #expect(try workspace.internalItemCount() == 0)
    }

    @Test("transient database busy leaves a recoverable phase")
    func databaseBusyCanRecover() async throws {
        let workspace = try WriterWorkspace()
        let databaseLock = DatabaseWriteLock()
        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            guard point == .beforeDomainTransaction else { return }
            let shouldLock = fired.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if shouldLock { try databaseLock.acquire(workspace.database) }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "busy")
        await #expect(throws: SQLiteStoreError.self) {
            _ = try await writer.create(
                payload: try workspace.payload(name: "Busy", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
        }
        #expect(try workspace.scalar("SELECT phase FROM skill_operations") == "filesystemApplied")
        #expect(try workspace.scalar("SELECT outcome FROM skill_operations") == nil)
        try databaseLock.release()

        try await writer.recoverAll()
        #expect(try workspace.scalar("SELECT outcome FROM skill_operations") == "applied")
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
    }

    @Test(
        "one corrupt journal record does not block another safe recovery",
        arguments: CorruptJournalField.allCases
    )
    func corruptRecordIsIsolated(_ field: CorruptJournalField) async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let corruptSkillID = SkillID()
        let corruptSnapshot = try workspace.snapshot(content: "corrupt")
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(
                    skillID: corruptSkillID,
                    name: "Corrupt",
                    snapshot: corruptSnapshot
                ),
                sourceSnapshot: corruptSnapshot
            )
            Issue.record("Expected prepared checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}

        let safeSnapshot = try workspace.snapshot(content: "safe")
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(name: "Safe", snapshot: safeSnapshot),
                sourceSnapshot: safeSnapshot
            )
            Issue.record("Expected prepared checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let mutation = switch field {
        case .payload:
            "UPDATE skill_operations SET domain_payload = X'00' "
        case .stagedIdentity:
            "UPDATE skill_operations SET expected_staged_identity = zeroblob(32) "
        }
        try workspace.mutateIgnoringTrigger(
            named: "skill_operations_immutable_ownership",
            mutation + "WHERE final_locator = '\(corruptSkillID.directoryName)'"
        )

        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await workspace.openWriter()
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try workspace.scalar("SELECT display_name FROM skills") == "Safe")
        #expect(try workspace.scalar(
            "SELECT outcome FROM skill_operations "
                + "WHERE final_locator = '\(corruptSkillID.directoryName)'"
        ) == "needsRepair")
        #expect(try workspace.internalItemCount() == 1)

        await #expect(throws: JournaledSSOTWriterError.self) {
            _ = try await workspace.openWriter()
        }
    }

    private func replacementContext() async throws -> ReplacementContext {
        let workspace = try WriterWorkspace()
        var writer: JournaledSSOTWriter? = try await workspace.openWriter()
        let skillID = SkillID()
        let oldSnapshot = try workspace.snapshot(content: "old")
        let old = try await writer!.create(
            payload: try workspace.payload(skillID: skillID, name: "Old", snapshot: oldSnapshot),
            sourceSnapshot: oldSnapshot
        )
        writer = nil
        return ReplacementContext(workspace: workspace, skillID: skillID, old: old)
    }

    private func replace(
        _ context: ReplacementContext,
        writer: JournaledSSOTWriter
    ) async throws -> SSOTJournalRecord {
        let snapshot = try context.workspace.snapshot(content: "new")
        return try await writer.replace(
            payload: try context.workspace.payload(
                skillID: context.skillID,
                name: "New",
                snapshot: snapshot
            ),
            sourceSnapshot: snapshot,
            expectedOld: try SSOTReplacementExpectation(
                identity: context.old.expectedNewIdentity,
                fingerprint: context.old.newFingerprint,
                databaseRevision: 0
            )
        )
    }
}

private struct ReplacementContext: Sendable {
    let workspace: WriterWorkspace
    let skillID: SkillID
    let old: SSOTJournalRecord
}

private final class DatabaseWriteLock: @unchecked Sendable {
    private var connection: SQLiteConnection?

    func acquire(_ database: URL) throws {
        let connection = try SQLiteConnection(url: database)
        try connection.execute("BEGIN IMMEDIATE")
        self.connection = connection
    }

    func release() throws {
        try connection?.execute("ROLLBACK")
        connection = nil
    }
}
