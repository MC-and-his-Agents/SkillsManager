import Foundation
import Synchronization
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT Skill deletion", .serialized)
struct JournaledSSOTWriterDeletionTests {
    private enum Stop: Error { case requested }

    @Test("deletes only after a valid backup and restores idempotently")
    func deletesAndRestores() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "recoverable")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: skillID,
                name: "Recoverable",
                snapshot: snapshot
            ),
            sourceSnapshot: snapshot
        )

        let deletion = try await writer.deleteManagedSkill(skillID: skillID)
        #expect(deletion.status == .completed)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
        #expect(!FileManager.default.fileExists(
            atPath: workspace.root.appendingPathComponent(skillID.directoryName).path
        ))

        let backups = try await writer.listBackups(originalSkillID: skillID)
        #expect(backups.count == 1)
        #expect(backups[0].state == .available)
        let restored = try await writer.restoreBackup(backups[0].backupID)
        let repeated = try await writer.restoreBackup(backups[0].backupID)
        #expect(restored.restoredSkillID == skillID)
        #expect(repeated.restoredSkillID == restored.restoredSkillID)
        #expect(repeated.status == restored.status)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
    }

    @Test(
        "restart converges each durable deletion phase",
        arguments: SkillDeletionCheckpoint.allCases
    )
    func recoversDeletion(point: SkillDeletionCheckpoint) async throws {
        let workspace = try WriterWorkspace()
        let fired = Mutex(false)
        var hooks = JournaledSSOTWriterHooks()
        hooks.deletionCheckpoint = { reached in
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
        _ = try await writer!.create(
            payload: workspace.payload(skillID: skillID, name: "Crash", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        do {
            _ = try await writer!.deleteManagedSkill(skillID: skillID)
            Issue.record("Expected deletion checkpoint interruption")
        } catch is SSOTWriterCheckpointInterruption {}
        writer = nil

        let recovered = try await workspace.openWriter()
        let skillCount = try workspace.integer("SELECT count(*) FROM skills")
        if point == .afterDatabaseCommitted || point == .beforeCleanup {
            #expect(skillCount == 0)
        } else {
            #expect(skillCount == 1)
            #expect(FileManager.default.fileExists(
                atPath: workspace.root.appendingPathComponent(skillID.directoryName).path
            ))
        }
        let backups = try await recovered.listBackups(originalSkillID: skillID)
        #expect(backups.count == 1)
        #expect(backups[0].state == .available)
    }

    @Test("missing prepared backup cancels without deleting the active Skill")
    func cancelsMissingPreparedBackup() async throws {
        let workspace = try WriterWorkspace()
        let operationID = SSOTOperationID()
        let backupID = SkillBackupID()
        var hooks = JournaledSSOTWriterHooks()
        hooks.deletionCheckpoint = { point in
            if point == .afterPreparedInsert { throw Stop.requested }
        }
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "still-active")
        let skillID = SkillID()
        _ = try await writer!.create(
            payload: workspace.payload(skillID: skillID, name: "Active", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer!.deleteManagedSkill(
                skillID: skillID,
                operationID: operationID,
                backupID: backupID
            )
        }
        writer = nil
        let staging = workspace.managementRoot
            .appendingPathComponent("skill-backups")
            .appendingPathComponent(skillID.directoryName)
            .appendingPathComponent(
                ".skillsmanager-backup-\(backupID.uuid.uuidString.lowercased()).tmp"
            )
        try FileManager.default.removeItem(at: staging)

        let recovered = try await workspace.openWriter()
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
        #expect(try await recovered.listBackups(originalSkillID: skillID).isEmpty)
        let operation = try await recovered.deletionOperation(operationID)
        #expect(operation.lastError == nil)
        #expect(operation.phase == .completed)
        #expect(operation.outcome == .rolledBack)
    }

    @Test("different active content restores to one stable fork identity")
    func restoresConflictAsIndependentSkill() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let original = try workspace.snapshot(content: "original")
        let originalID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: originalID,
                name: "Original",
                snapshot: original
            ),
            sourceSnapshot: original
        )
        _ = try await writer.deleteManagedSkill(skillID: originalID)
        let backup = try await writer.listBackups(originalSkillID: originalID)[0]

        let replacement = try workspace.snapshot(content: "replacement")
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: originalID,
                name: "Replacement",
                snapshot: replacement
            ),
            sourceSnapshot: replacement
        )
        let restored = try await writer.restoreBackup(backup.backupID)
        let repeated = try await writer.restoreBackup(backup.backupID)
        #expect(restored.restoredSkillID != originalID)
        #expect(repeated.restoredSkillID == restored.restoredSkillID)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 2)
    }

    @Test("tampered backup fails closed")
    func rejectsTamperedBackup() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "trusted")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Trusted", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        _ = try await writer.deleteManagedSkill(skillID: skillID)
        let backup = try await writer.listBackups(originalSkillID: skillID)[0]
        let file = workspace.managementRoot
            .appendingPathComponent("skill-backups")
            .appendingPathComponent(backup.locator)
            .appendingPathComponent("skill-files/SKILL.md")
        try Data("tampered".utf8).write(to: file)

        await #expect(throws: (any Error).self) {
            _ = try await writer.restoreBackup(backup.backupID)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
    }

    @Test("retention keeps the newest ten valid backups")
    func prunesOldBackups() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.nowMilliseconds = { 1 }
        let writer = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "retained")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Retained", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        for _ in 0..<11 {
            _ = try await writer.deleteManagedSkill(skillID: skillID)
            let backup = try await writer.listBackups(originalSkillID: skillID)
                .first { $0.restoreResultJSON == nil }!
            _ = try await writer.restoreBackup(backup.backupID)
        }

        let result = try await writer.runBackupRetention(
            originalSkillID: skillID,
            nowMilliseconds: 31 * 24 * 60 * 60 * 1_000
        )
        #expect(result.prunedBackupIDs.count == 1)
        #expect(try await writer.listBackups(originalSkillID: skillID).count == 10)
    }
}
