import Foundation
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT lifecycle previews", .serialized)
struct JournaledSSOTWriterLifecyclePreviewTests {
    private enum Stop: Error { case requested }

    @Test("deletion preview includes verified content and global backup catalog survives deletion")
    func previewAndCatalog() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "catalog")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Catalog", snapshot: snapshot),
            sourceSnapshot: snapshot
        )

        let preview = try await writer.deletionPreview(skillID: skillID)
        #expect(preview.status == .ready)
        #expect(preview.content?.displayName == "Catalog")
        #expect(preview.content?.statistics.fileCount == 1)
        #expect(preview.token != nil)

        _ = try await writer.deleteManagedSkill(preview: preview)
        let catalog = try await writer.backupCatalog()
        #expect(catalog.count == 1)
        #expect(catalog[0].originalSkillID == skillID)
        #expect(catalog[0].availability == .available)
        #expect(catalog[0].summary?.content.displayName == "Catalog")
    }

    @Test("deletion rejects an expired preview expectation")
    func deleteRejectsExpiredPreviewExpectation() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "stale-delete")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Stale", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        let preview = try await writer.deletionPreview(skillID: skillID)

        let connection = try SQLiteConnection(url: workspace.database)
        try connection.execute("UPDATE skills SET db_revision = db_revision + 1")

        await #expect(throws: SkillDeletionError.previewExpired) {
            _ = try await writer.deleteManagedSkill(preview: preview)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
    }

    @Test("backup catalog isolates corrupt entries")
    func backupCatalogIsolatesCorruptEntry() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "corrupt")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Corrupt", snapshot: snapshot),
            sourceSnapshot: snapshot
        )
        _ = try await writer.deleteManagedSkill(
            preview: try await writer.deletionPreview(skillID: skillID)
        )
        let backup = try await writer.listBackups(originalSkillID: skillID)[0]
        let file = workspace.managementRoot
            .appendingPathComponent("skill-backups")
            .appendingPathComponent(backup.locator)
            .appendingPathComponent("skill-files/SKILL.md")
        try Data("tampered".utf8).write(to: file)

        let catalog = try await writer.backupCatalog()
        #expect(catalog.count == 1)
        #expect(catalog[0].availability == .corrupt)
        #expect(catalog[0].problem == .backupCorrupt)
        #expect(catalog[0].summary == nil)
    }

    @Test("restore rejects an expired target expectation")
    func restoreRejectsExpiredTargetExpectation() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let original = try workspace.snapshot(content: "original")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Original", snapshot: original),
            sourceSnapshot: original
        )
        _ = try await writer.deleteManagedSkill(
            preview: try await writer.deletionPreview(skillID: skillID)
        )
        let backup = try await writer.listBackups(originalSkillID: skillID)[0]
        let preview = try await writer.restorePreview(backup.backupID)

        let replacement = try workspace.snapshot(content: "replacement")
        _ = try await writer.create(
            payload: workspace.payload(
                skillID: skillID,
                name: "Replacement",
                snapshot: replacement
            ),
            sourceSnapshot: replacement
        )

        await #expect(throws: SkillDeletionError.previewExpired) {
            _ = try await writer.restoreBackup(preview: preview)
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
    }

    @Test("post-commit cleanup remains discoverable after interruption")
    func recoverableDeletionCatalogFindsPostCommitCleanup() async throws {
        let workspace = try WriterWorkspace()
        var hooks = JournaledSSOTWriterHooks()
        hooks.deletionCheckpoint = { point in
            if point == .beforeCleanup { throw Stop.requested }
        }
        let writer = try await workspace.openWriter(hooks: hooks)
        let snapshot = try workspace.snapshot(content: "cleanup")
        let skillID = SkillID()
        _ = try await writer.create(
            payload: workspace.payload(skillID: skillID, name: "Cleanup", snapshot: snapshot),
            sourceSnapshot: snapshot
        )

        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer.deleteManagedSkill(
                preview: try await writer.deletionPreview(skillID: skillID)
            )
        }

        let readbacks = try await writer.recoverableDeletionReadbacks()
        #expect(readbacks.count == 1)
        #expect(readbacks[0].skillID == skillID)
        #expect(readbacks[0].status == .cleanupPending)
        #expect(try workspace.integer("SELECT count(*) FROM skills") == 0)
    }
}
