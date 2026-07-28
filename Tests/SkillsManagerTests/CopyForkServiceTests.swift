import Foundation
import Testing

@testable import SkillsManager

@Suite("Copy Fork service", .serialized)
struct CopyForkServiceTests {
    @Test("preserves content-only global Copy drift as an independent Fork")
    func globalCopyFork() async throws {
        let fixture = try await PreparedCopyFork()
        let preview = try await fixture.writer.copyForkPreview(
            parentSkillID: fixture.parentSkillID,
            scope: .global
        )
        let result = try await fixture.writer.createCopyFork(preview)
        let repeated = try await fixture.writer.createCopyFork(preview)

        #expect(result == repeated)
        #expect(result.childSkillID == preview.childSkillID)
        let parent = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.parentSkillID
        )
        let child = try await fixture.writer.loadDistributionSelection(
            skillID: result.childSkillID
        )
        let childDomain = try #require(
            try await fixture.writer.storedDomainReadback(result.childSkillID)
        )
        #expect(parent.bindings.isEmpty)
        #expect(child.bindings.count == 1)
        #expect(child.bindings.first?.scope == .global)
        #expect(
            child.bindings.first?.copyBaseline?.provenance
                == .copyFork(result.operationID)
        )
        #expect(childDomain.payload.source == nil)
        #expect(childDomain.payload.providerAliases.isEmpty)
        #expect(childDomain.payload.providerProvenance.isEmpty)
        #expect(childDomain.payload.localOrigins.isEmpty)
        #expect(childDomain.payload.forkLineage?.parentSkillID == fixture.parentSkillID)
        #expect(
            childDomain.payload.forkLineage?.forkedFromFingerprint
                == fixture.parentBaseline
        )
        #expect(try String(
            contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "locally changed")
    }

    @Test("moves only the selected Agent Copy and preserves the parent's other binding")
    func agentCopyFork() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        let parentID = try await prepareParentCopy(workspace: workspace, writer: writer)
        let slug = try DefaultDistributionSlug(validating: "parent")
        let agents: Set<SkillPlatform> = [.codex, .claude]
        let plan = try await writer.distributionPlan(
            skillID: parentID,
            desiredConfiguration: .init(
                scope: .agents(agents, slug),
                syncMode: .copy
            ),
            requiredAdapterCodes: Set(agents.map(\.storageKey))
        )
        _ = try await writer.applyDistribution(skillID: parentID, plan: plan)
        let codexTarget = workspace.distributionHomeURL
            .appendingPathComponent(".codex/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        try Data("codex fork".utf8).write(
            to: codexTarget.appendingPathComponent("SKILL.md")
        )

        let result = try await writer.createCopyFork(
            writer.copyForkPreview(
                parentSkillID: parentID,
                scope: .agent(.codex)
            )
        )
        let parent = try await writer.loadDistributionSelection(skillID: parentID)
        let child = try await writer.loadDistributionSelection(skillID: result.childSkillID)

        #expect(parent.bindings.map(\.scope) == [.agent(.claude)])
        #expect(child.bindings.map(\.scope) == [.agent(.codex)])
        #expect(
            child.bindings.first?.copyBaseline?.provenance
                == .copyFork(result.operationID)
        )
    }

    @Test("completed readback rejects later physical drift")
    func completedReadbackRejectsPhysicalDrift() async throws {
        let fixture = try await PreparedCopyFork()
        let preview = try await fixture.writer.copyForkPreview(
            parentSkillID: fixture.parentSkillID,
            scope: .global
        )
        _ = try await fixture.writer.createCopyFork(preview)
        try FileManager.default.createDirectory(
            at: fixture.copyURL.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: false
        )

        await #expect(throws: CopyForkError.needsRepair) {
            _ = try await fixture.writer.createCopyFork(preview)
        }
    }

    @Test("v3 distribution removal recovers idempotently")
    func v3DistributionRemovalRecovery() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        var writer: JournaledSSOTWriter? = try await workspace.openWriter()
        let parentID = try await prepareParentCopy(workspace: workspace, writer: writer!)
        let slug = try DefaultDistributionSlug(validating: "parent")
        let copyURL = workspace.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let fork = try await writer!.createCopyFork(
            writer!.copyForkPreview(parentSkillID: parentID, scope: .global)
        )
        let remove = try await writer!.distributionPlan(
            skillID: fork.childSkillID,
            desiredConfiguration: .init(scope: .disabled, syncMode: .copy),
            requiredAdapterCodes: []
        )
        let operation = try await writer!.applyDistribution(
            skillID: fork.childSkillID,
            plan: remove
        )
        #expect(operation.formatVersion == 3)
        writer = nil
        try workspace.execute(
            """
            UPDATE distribution_operations
            SET phase = 'databaseCommitted', outcome = NULL, cleanup_cursor = 0
            WHERE operation_id = X'\(lowerHex(operation.operationID.bytes))'
            """
        )

        let recovered = try await workspace.openWriter()
        _ = recovered
        #expect(try workspace.scalar(
            "SELECT phase FROM distribution_operations "
                + "WHERE operation_id = X'\(lowerHex(operation.operationID.bytes))'"
        ) == "completed")
        #expect(try workspace.scalar(
            "SELECT outcome FROM distribution_operations "
                + "WHERE operation_id = X'\(lowerHex(operation.operationID.bytes))'"
        ) == "applied")
    }

    @Test("rejects physical drift and stale preview without reserving")
    func rejectsUnsafeAndStaleInput() async throws {
        let physical = try await PreparedCopyFork()
        try Data("metadata".utf8).write(
            to: physical.copyURL.appendingPathComponent(".DS_Store")
        )
        await #expect(throws: CopyForkError.notContentOnlyDrift) {
            _ = try await physical.writer.copyForkPreview(
                parentSkillID: physical.parentSkillID,
                scope: .global
            )
        }
        #expect(try physical.workspace.integer(
            "SELECT count(*) FROM copy_fork_operations"
        ) == 0)

        let stale = try await PreparedCopyFork()
        let preview = try await stale.writer.copyForkPreview(
            parentSkillID: stale.parentSkillID,
            scope: .global
        )
        try Data("changed again".utf8).write(
            to: stale.copyURL.appendingPathComponent("SKILL.md")
        )
        await #expect(throws: CopyForkError.previewExpired) {
            _ = try await stale.writer.createCopyFork(preview)
        }
        #expect(try stale.workspace.integer(
            "SELECT count(*) FROM copy_fork_operations"
        ) == 0)
        #expect(try stale.workspace.integer(
            "SELECT count(*) FROM skills"
        ) == 1)
    }

    @Test("an existing backup write blocks Copy Fork reservation without mutation")
    func existingBackupBlocksReservation() async throws {
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        let parentID = try await prepareParentCopy(workspace: workspace, writer: writer)
        let slug = try DefaultDistributionSlug(validating: "parent")
        let copyURL = workspace.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let fork = try await writer.copyForkPreview(
            parentSkillID: parentID,
            scope: .global
        )
        try workspace.execute(
            """
            INSERT INTO skill_backups(
              backup_id, format_version, original_skill_id, state, locator,
              directory_identity, manifest_digest,
              fingerprint_algorithm_version, content_fingerprint,
              created_at_ms, updated_at_ms
            )
            VALUES (
              randomblob(16), 1, X'\(lowerHex(parentID.bytes))', 'preparing',
              'test-active-backup', zeroblob(32), zeroblob(32), 1,
              zeroblob(32), 1, 1
            )
            """
        )

        await #expect(throws: CopyForkError.operationInProgress) {
            _ = try await writer.createCopyFork(fork)
        }
        #expect(try workspace.integer(
            "SELECT count(*) FROM copy_fork_operations"
        ) == 0)
    }

    @Test("deletion backup and restore preserve Fork lineage")
    func backupRestorePreservesLineage() async throws {
        let fixture = try await PreparedCopyFork()
        let fork = try await fixture.writer.createCopyFork(
            fixture.writer.copyForkPreview(
                parentSkillID: fixture.parentSkillID,
                scope: .global
            )
        )
        let deletion = try await fixture.writer.deleteManagedSkill(
            preview: fixture.writer.deletionPreview(skillID: fork.childSkillID)
        )
        let restored = try await fixture.writer.restoreBackup(
            preview: fixture.writer.restorePreview(deletion.backupID)
        )
        let domain = try #require(
            try await fixture.writer.storedDomainReadback(restored.restoredSkillID)
        )

        #expect(domain.payload.forkLineage?.parentSkillID == fixture.parentSkillID)
        #expect(
            domain.payload.forkLineage?.forkedFromFingerprint
                == fixture.parentBaseline
        )
    }
}

@Suite("Copy Fork recovery", .serialized)
struct CopyForkRecoveryTests {
    @Test(
        "reuses the preview child UUID after every persisted create checkpoint",
        arguments: [
            SSOTWriterCheckpoint.afterPreparedInsert,
            .afterCreatePromotion,
            .afterFilesystemPhase,
            .afterDomainTransaction,
            .afterTerminalCompletion,
        ]
    )
    func recoversInterruptedCreate(point: SSOTWriterCheckpoint) async throws {
        let interruption = CopyForkCheckpointInterruption()
        let workspace = try WriterWorkspace(distributionEnabled: true)
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(
            hooks: JournaledSSOTWriterHooks(checkpoint: interruption.reach)
        )
        let parentID = try await prepareParentCopy(workspace: workspace, writer: writer!)
        let slug = try DefaultDistributionSlug(validating: "parent")
        let copyURL = workspace.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let preview = try await writer!.copyForkPreview(
            parentSkillID: parentID,
            scope: .global
        )
        interruption.arm(at: point)
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer!.createCopyFork(preview)
        }
        let plan = try await writer!.distributionPlan(
            skillID: parentID,
            desiredConfiguration: DistributionDesiredConfiguration(
                scope: .global(slug),
                syncMode: .copy
            ),
            requiredAdapterCodes: globalReaderCodes
        )
        await #expect(throws: CopyForkError.operationInProgress) {
            _ = try await writer!.applyDistribution(skillID: parentID, plan: plan)
        }

        writer = nil
        let recovered = try await workspace.openWriter()
        let child = try #require(
            try await recovered.storedDomainReadback(preview.childSkillID)
        )
        #expect(child.payload.forkLineage?.parentSkillID == parentID)
        #expect(try await recovered.loadDistributionSelection(
            skillID: preview.childSkillID
        ).bindings.first?.copyBaseline?.provenance == .copyFork(preview.operationID))
        #expect(try workspace.integer(
            "SELECT count(*) FROM copy_fork_operations "
                + "WHERE phase = 'completed' AND outcome = 'applied'"
        ) == 1)
    }

    @Test("marks an unprovable child state as needs repair and keeps admission locked")
    func marksUnprovableChildNeedsRepair() async throws {
        let interruption = CopyForkCheckpointInterruption()
        let workspace = try WriterWorkspace(distributionEnabled: true)
        var writer: JournaledSSOTWriter? = try await workspace.openWriter(
            hooks: JournaledSSOTWriterHooks(checkpoint: interruption.reach)
        )
        let parentID = try await prepareParentCopy(workspace: workspace, writer: writer!)
        let slug = try DefaultDistributionSlug(validating: "parent")
        let copyURL = workspace.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let preview = try await writer!.copyForkPreview(
            parentSkillID: parentID,
            scope: .global
        )
        interruption.arm(at: .afterTerminalCompletion)
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer!.createCopyFork(preview)
        }
        try workspace.execute(
            """
            UPDATE skills
            SET display_name = 'tampered',
                default_distribution_slug = 'tampered',
                default_slug_key = 'tampered'
            WHERE skill_id = (
              SELECT child_skill_id FROM copy_fork_operations
            )
            """
        )
        writer = nil

        let recovered = try await workspace.openWriter()
        #expect(try workspace.scalar(
            "SELECT outcome FROM copy_fork_operations"
        ) == "needsRepair")
        let plan = try await recovered.distributionPlan(
            skillID: parentID,
            desiredConfiguration: DistributionDesiredConfiguration(
                scope: .global(slug),
                syncMode: .copy
            ),
            requiredAdapterCodes: globalReaderCodes
        )
        await #expect(throws: CopyForkError.operationInProgress) {
            _ = try await recovered.applyDistribution(skillID: parentID, plan: plan)
        }
    }

    @Test("restore is blocked before mutation by a Copy Fork target reservation")
    func restoreBlockedByTargetReservation() async throws {
        let interruption = CopyForkCheckpointInterruption()
        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter(
            hooks: JournaledSSOTWriterHooks(checkpoint: interruption.reach)
        )
        let backupSkillID = try await prepareParentCopy(
            workspace: workspace,
            writer: writer
        )
        let deletion = try await writer.deleteManagedSkill(
            preview: writer.deletionPreview(skillID: backupSkillID)
        )
        let restore = try await writer.restorePreview(deletion.backupID)
        let parentID = try await prepareParentCopy(workspace: workspace, writer: writer)
        let slug = try DefaultDistributionSlug(validating: "parent")
        let copyURL = workspace.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let fork = try await writer.copyForkPreview(
            parentSkillID: parentID,
            scope: .global
        )
        interruption.arm(at: .afterTerminalCompletion)
        await #expect(throws: SSOTWriterCheckpointInterruption.self) {
            _ = try await writer.createCopyFork(fork)
        }
        let skillCount = try workspace.integer("SELECT count(*) FROM skills")

        await #expect(throws: SkillDeletionError.operationInProgress) {
            _ = try await writer.restoreBackup(
                preview: restore,
                restoreDistribution: true
            )
        }
        #expect(try workspace.integer("SELECT count(*) FROM skills") == skillCount)
        #expect(try workspace.integer(
            "SELECT count(*) FROM skill_backups WHERE restored_skill_id IS NOT NULL"
        ) == 0)
    }
}

private struct PreparedCopyFork {
    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let parentSkillID: SkillID
    let parentBaseline: SkillContentFingerprint
    let copyURL: URL

    init() async throws {
        workspace = try WriterWorkspace(distributionEnabled: true)
        writer = try await workspace.openWriter()
        parentSkillID = try await prepareParentCopy(workspace: workspace, writer: writer)
        let selection = try await writer.loadDistributionSelection(skillID: parentSkillID)
        parentBaseline = try #require(
            selection.bindings.first?.copyBaseline?.contentFingerprint
        )
        let slug = try DefaultDistributionSlug(validating: "parent")
        copyURL = workspace.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
    }
}

private let globalReaderCodes = Set(
    DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
)

private func prepareParentCopy(
    workspace: WriterWorkspace,
    writer: JournaledSSOTWriter
) async throws -> SkillID {
    let skillID = SkillID()
    let snapshot = try workspace.snapshot(content: "original")
    _ = try await writer.create(
        payload: workspace.payload(skillID: skillID, name: "Parent", snapshot: snapshot),
        sourceSnapshot: snapshot
    )
    let slug = try DefaultDistributionSlug(validating: "parent")
    let plan = try await writer.distributionPlan(
        skillID: skillID,
        desiredConfiguration: DistributionDesiredConfiguration(
            scope: .global(slug),
            syncMode: .copy
        ),
        requiredAdapterCodes: globalReaderCodes
    )
    _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
    return skillID
}

private final class CopyForkCheckpointInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var point: SSOTWriterCheckpoint?

    func arm(at point: SSOTWriterCheckpoint) {
        lock.lock()
        self.point = point
        lock.unlock()
    }

    func reach(_ checkpoint: SSOTWriterCheckpoint, _: SSOTOperationID) throws {
        lock.lock()
        let shouldStop = checkpoint == point
        if shouldStop { point = nil }
        lock.unlock()
        if shouldStop {
            throw SSOTWriterCheckpointInterruption(detail: "test interruption")
        }
    }

}
