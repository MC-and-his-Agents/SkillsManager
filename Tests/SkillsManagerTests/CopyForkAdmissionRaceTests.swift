import Foundation
import Testing

@testable import SkillsManager

@Suite("Copy Fork admission races", .serialized)
struct CopyForkAdmissionRaceTests {
    @Test("an earlier deletion blocks reservation and still recovers")
    func deletionWinsReservationRace() async throws {
        let interruption = DeletionCheckpointInterruption(
            target: .afterDistributionRemoved
        )
        let workspace = try WriterWorkspace(distributionEnabled: true)
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(
            hooks: JournaledSSOTWriterHooks(
                deletionCheckpoint: interruption.reach
            )
        )
        let deletingID = try await prepareParentCopy(
            workspace: workspace,
            writer: writer!
        )
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer!.deleteManagedSkill(
                preview: writer!.deletionPreview(skillID: deletingID)
            )
        }
        let parentID = try await prepareParentCopy(
            workspace: workspace,
            writer: writer!
        )
        let copyURL = try copyForkGlobalURL(workspace)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let preview = try await writer!.copyForkPreview(
            parentSkillID: parentID,
            scope: .global
        )

        await #expect(throws: CopyForkError.operationInProgress) {
            _ = try await writer!.createCopyFork(preview)
        }
        #expect(try workspace.integer(
            "SELECT count(*) FROM copy_fork_operations"
        ) == 0)
        try Data("original".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        try await disableCopyDistribution(writer: writer!, skillID: parentID)
        writer = nil

        let recovered = try await workspace.openWriter()
        #expect(try await recovered.storedDomainReadback(deletingID) != nil)
        #expect(try workspace.integer(
            "SELECT count(*) FROM skill_deletion_operations "
                + "WHERE outcome IN ('pending', 'needsRepair')"
        ) == 0)
    }

    @Test("an unfinished restore blocks reservation and can finish")
    func restoreWinsReservationRace() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        var writer: JournaledSSOTWriter? = try await workspace.openWriter()
        let restoringID = try await prepareParentCopy(
            workspace: workspace,
            writer: writer!
        )
        let deletion = try await writer!.deleteManagedSkill(
            preview: writer!.deletionPreview(skillID: restoringID)
        )
        writer = nil

        let interruption = CopyForkCheckpointInterruption()
        writer = try await workspace.openWriter(
            hooks: JournaledSSOTWriterHooks(checkpoint: interruption.reach)
        )
        let restore = try await writer!.restorePreview(deletion.backupID)
        interruption.arm(at: .afterTerminalCompletion)
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer!.restoreBackup(
                preview: restore,
                restoreDistribution: true
            )
        }
        #expect(try workspace.integer(
            "SELECT count(*) FROM skill_backups "
                + "WHERE restored_skill_id IS NOT NULL "
                + "AND restore_result_json IS NULL"
        ) == 1)
        let parentID = try await prepareParentCopy(
            workspace: workspace,
            writer: writer!
        )
        let copyURL = try copyForkGlobalURL(workspace)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let preview = try await writer!.copyForkPreview(
            parentSkillID: parentID,
            scope: .global
        )

        await #expect(throws: CopyForkError.operationInProgress) {
            _ = try await writer!.createCopyFork(preview)
        }
        #expect(try workspace.integer(
            "SELECT count(*) FROM copy_fork_operations"
        ) == 0)
        try Data("original".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        try await disableCopyDistribution(writer: writer!, skillID: parentID)
        writer = nil

        let recovered = try await workspace.openWriter()
        let result = try await recovered.restoreBackup(
            preview: recovered.restorePreview(deletion.backupID),
            restoreDistribution: true
        )
        #expect(result.status == .completed)
        #expect(try workspace.integer(
            "SELECT count(*) FROM skill_backups "
                + "WHERE restored_skill_id IS NOT NULL "
                + "AND restore_result_json IS NULL"
        ) == 0)
    }
}

private func copyForkGlobalURL(_ workspace: WriterWorkspace) throws -> URL {
    let slug = try DefaultDistributionSlug(validating: "parent")
    return workspace.workspace
        .appendingPathComponent(".agents/skills", isDirectory: true)
        .appendingPathComponent(slug.value, isDirectory: true)
}

private func disableCopyDistribution(
    writer: JournaledSSOTWriter,
    skillID: SkillID
) async throws {
    let plan = try await writer.distributionPlan(
        skillID: skillID,
        desiredConfiguration: .init(scope: .disabled, syncMode: .copy),
        requiredAdapterCodes: []
    )
    _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
}

private final class DeletionCheckpointInterruption: @unchecked Sendable {
    private let target: SkillDeletionCheckpoint
    private let lock = NSLock()
    private var fired = false

    init(target: SkillDeletionCheckpoint) {
        self.target = target
    }

    func reach(_ checkpoint: SkillDeletionCheckpoint) throws {
        lock.lock()
        let shouldStop = checkpoint == target && !fired
        if shouldStop { fired = true }
        lock.unlock()
        if shouldStop {
            throw SSOTWriterCheckpointInterruption(detail: "test interruption")
        }
    }
}
