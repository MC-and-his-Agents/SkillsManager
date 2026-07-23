import Darwin
import Foundation
import Synchronization
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT writer")
struct JournaledSSOTWriterTests {
    private enum Stop: Error { case requested }

    @Test("create and same-content replacement complete")
    func createsAndReplacesSameContent() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let first = try workspace.snapshot(content: "same")
        let skillID = SkillID()
        let created = try await writer.create(
            payload: try workspace.payload(skillID: skillID, name: "First", snapshot: first),
            sourceSnapshot: first
        )
        let replacement = try workspace.snapshot(content: "same")
        let replaced = try await writer.replace(
            payload: try workspace.payload(
                skillID: skillID,
                name: "Renamed",
                snapshot: replacement
            ),
            sourceSnapshot: replacement,
            expectedOld: try SSOTReplacementExpectation(
                identity: created.expectedNewIdentity,
                fingerprint: created.newFingerprint,
                databaseRevision: 0
            )
        )

        #expect(created.state == .init(
            phase: .completed,
            outcome: .applied,
            cleanupState: .notApplicable
        ))
        #expect(replaced.state == .init(
            phase: .completed,
            outcome: .applied,
            cleanupState: .completed
        ))
        #expect(replaced.newFingerprint == created.newFingerprint)
        #expect(try workspace.scalar("SELECT display_name FROM skills") == "Renamed")
        #expect(try workspace.integer("SELECT db_revision FROM skills") == 1)
    }

    @Test(
        "create converges after every persisted writer checkpoint",
        arguments: [
            SSOTWriterCheckpoint.afterPreparedInsert,
            .afterCreatePromotion,
            .afterFilesystemPhase,
            .afterDomainTransaction,
            .afterTerminalCompletion,
        ]
    )
    func recoversCreate(point: SSOTWriterCheckpoint) async throws {
        let workspace = try WriterWorkspace()
        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { reached, _ in
            guard reached == point else { return }
            let shouldStop = fired.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if shouldStop { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: point.rawValue)
        let skillID = SkillID()
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(skillID: skillID, name: "Crash", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
            Issue.record("Expected checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let recovered = try await workspace.openWriter()
        _ = recovered
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(FileManager.default.fileExists(
            atPath: workspace.root.appendingPathComponent(skillID.directoryName).path
        ))
        #expect(try workspace.integer(
            "SELECT count(*) FROM skill_operations WHERE phase = 'completed' AND outcome = 'applied'"
        ) == 1)
    }

    @Test("rename interruption re-establishes parent durability before phase advance")
    func recoversAfterRenameBeforeParentSync() async throws {
        let workspace = try WriterWorkspace()
        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.fileSystemCheckpoint = { point in
            guard point == .afterCreateRenameBeforeParentSync else { return }
            let shouldStop = fired.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if shouldStop { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "rename")
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(name: "Rename", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
            Issue.record("Expected checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let recovered = try await workspace.openWriter()
        _ = recovered
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
    }

    @Test("prepared cancellation removes only its staging item and rolls back")
    func cancelsPreparedWrite() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "cancel")
        let write = Task {
            try await writer.create(
                payload: workspace.payload(name: "Cancel", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await write.value
        }
        #expect(try workspace.scalar("SELECT outcome FROM skill_operations") == "rolledBack")
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
        #expect(try workspace.internalItemCount() == 0)
    }

    @Test("recovery timestamps do not move backward with the wall clock")
    func toleratesClockRollback() async throws {
        let workspace = try WriterWorkspace()
        var crashHooks = JournaledSSOTWriterHooks()
        crashHooks.nowMilliseconds = { 1_000 }
        crashHooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: crashHooks)
        let snapshot = try workspace.snapshot(content: "clock")
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(name: "Clock", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        var recoveryHooks = JournaledSSOTWriterHooks()
        recoveryHooks.nowMilliseconds = { 1 }
        let recovered = try await workspace.openWriter(hooks: recoveryHooks)
        _ = recovered
        #expect(try workspace.integer("SELECT updated_at_ms FROM skill_operations") == 1_000)
        #expect(try workspace.scalar("SELECT outcome FROM skill_operations") == "applied")
    }

    @Test(
        "replacement resumes from persisted checkpoints",
        arguments: [
            SSOTWriterCheckpoint.afterPreparedInsert,
            SSOTWriterCheckpoint.afterReplacementSwap,
            .afterFilesystemPhase,
            .afterDomainTransaction,
            .afterTerminalCompletion,
        ]
    )
    func recoversReplacement(point: SSOTWriterCheckpoint) async throws {
        let workspace = try WriterWorkspace()
        var writer: JournaledSSOTWriter? = try await workspace.openWriter()
        let skillID = SkillID()
        let oldSnapshot = try workspace.snapshot(content: "old")
        let old = try await writer!.create(
            payload: try workspace.payload(skillID: skillID, name: "Old", snapshot: oldSnapshot),
            sourceSnapshot: oldSnapshot
        )
        writer = nil

        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { reached, _ in
            guard reached == point else { return }
            let shouldStop = fired.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if shouldStop { throw Stop.requested }
        }
        writer = try await workspace.openWriter(hooks: hooks)
        let newSnapshot = try workspace.snapshot(content: "new")
        do {
            _ = try await writer!.replace(
                payload: try workspace.payload(skillID: skillID, name: "New", snapshot: newSnapshot),
                sourceSnapshot: newSnapshot,
                expectedOld: try SSOTReplacementExpectation(
                    identity: old.expectedNewIdentity,
                    fingerprint: old.newFingerprint,
                    databaseRevision: 0
                )
            )
            Issue.record("Expected checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let recovered = try await workspace.openWriter()
        _ = recovered
        #expect(try workspace.scalar("SELECT display_name FROM skills") == "New")
        #expect(try workspace.integer("SELECT db_revision FROM skills") == 1)
        #expect(try workspace.scalar(
            "SELECT outcome FROM skill_operations WHERE operation_type = 'replace'"
        ) == "applied")
    }

    @Test("ordinary replacement cleanup failure becomes a retryable debt")
    func recordsAndRetriesCleanupDebt() async throws {
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
        let replaced = try await writer!.replace(
            payload: try workspace.payload(skillID: skillID, name: "New", snapshot: newSnapshot),
            sourceSnapshot: newSnapshot,
            expectedOld: try SSOTReplacementExpectation(
                identity: old.expectedNewIdentity,
                fingerprint: old.newFingerprint,
                databaseRevision: 0
            )
        )
        #expect(replaced.state.cleanupState == .pending)
        #expect(try workspace.integer("SELECT count(*) FROM cleanup_debts") == 1)
        writer = nil

        let recovered = try await workspace.openWriter()
        _ = recovered
        #expect(try workspace.integer("SELECT count(*) FROM cleanup_debts") == 0)
        #expect(try workspace.scalar(
            "SELECT cleanup_state FROM skill_operations WHERE operation_type = 'replace'"
        ) == "completed")
    }

    @Test("one damaged operation does not prevent another recovery")
    func continuesAfterNeedsRepair() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let firstID = SkillID()
        let secondID = SkillID()
        for (skillID, content) in [(firstID, "first"), (secondID, "second")] {
            let snapshot = try workspace.snapshot(content: content)
            do {
                _ = try await writer.create(
                    payload: try workspace.payload(
                        skillID: skillID,
                        name: content,
                        snapshot: snapshot
                    ),
                    sourceSnapshot: snapshot
                )
            } catch is SSOTWriterCheckpointInterruption {}
        }
        let firstOperation = try workspace.operationID(for: firstID)
        let staged = workspace.root.appendingPathComponent(
            ".skillsmanager-tmp-\(firstOperation.uuidString.lowercased())"
        )
        try Data("tampered".utf8).write(
            to: staged.appendingPathComponent("SKILL.md"),
            options: .atomic
        )

        await #expect(throws: JournaledSSOTWriterError.self) {
            try await writer.recoverAll()
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(FileManager.default.fileExists(
            atPath: workspace.root.appendingPathComponent(secondID.directoryName).path
        ))
        #expect(try workspace.scalar(
            "SELECT outcome FROM skill_operations WHERE skill_id = x'\(firstID.bytes.hex)'"
        ) == "needsRepair")
    }

    @Test("second writer reports busy before opening another database writer")
    func rejectsSecondWriter() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        _ = writer
        await #expect(throws: SSOTWriterOwnershipError.self) {
            _ = try await workspace.openWriter()
        }
    }

    @Test("named lock drift blocks recovery without changing the journal")
    func lockDriftFailsClosed() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "lock")
        do {
            _ = try await writer.create(
                payload: try workspace.payload(name: "Lock", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
        } catch is SSOTWriterCheckpointInterruption {}
        let lock = workspace.managementRoot
            .appendingPathComponent(SSOTWriterOwnership.lockFileName)
        try FileManager.default.removeItem(at: lock)
        try Data("replacement\n".utf8).write(to: lock)
        #expect(Darwin.chmod(lock.path, 0o600) == 0)

        await #expect(throws: SSOTWriterOwnershipError.invalidLockFile) {
            try await writer.recoverAll()
        }
        #expect(try workspace.scalar("SELECT outcome FROM skill_operations") == nil)
        #expect(try workspace.scalar("SELECT phase FROM skill_operations") == "prepared")
    }

    @Test("root replacement blocks reopen without changing the journal")
    func rootDriftFailsClosed() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.checkpoint = { point, _ in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "root")
        do {
            _ = try await writer!.create(
                payload: try workspace.payload(name: "Root", snapshot: snapshot),
                sourceSnapshot: snapshot
            )
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil
        let moved = workspace.workspace.appendingPathComponent("old-skills")
        try FileManager.default.moveItem(at: workspace.root, to: moved)
        try FileManager.default.createDirectory(
            at: workspace.root,
            withIntermediateDirectories: false
        )
        #expect(Darwin.chmod(workspace.root.path, 0o700) == 0)

        await #expect(throws: ManagedPathError.rootReplaced) {
            _ = try await workspace.openWriter()
        }
        #expect(try workspace.scalar("SELECT outcome FROM skill_operations") == nil)
        #expect(try workspace.scalar("SELECT phase FROM skill_operations") == "prepared")
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
