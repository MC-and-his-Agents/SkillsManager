import Foundation
import Testing

@testable import SkillsManager

@Suite("Journaled SSOT Copy lifecycle", .serialized)
struct JournaledSSOTWriterCopyDeletionTests {
    @Test("does not adopt matching SSOT and target edits as a new baseline")
    func matchingEditsRemainDrift() async throws {
        let fixture = try await CopyDeletionFixture()
        let changed = Data("same external edit".utf8)
        try changed.write(
            to: fixture.workspace.root
                .appendingPathComponent(
                    fixture.skillID.directoryName,
                    isDirectory: true
                )
                .appendingPathComponent("SKILL.md")
        )
        try changed.write(to: fixture.copyURL.appendingPathComponent("SKILL.md"))
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        let slug = try #require(selection.bindings.first?.distributionSlug)

        let plan = try await fixture.writer.distributionPlan(
            skillID: fixture.skillID,
            desiredConfiguration: .init(scope: .global(slug), syncMode: .copy),
            requiredAdapterCodes: Set(
                DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
            )
        )

        #expect(plan.status == .blocked)
        #expect(plan.conflicts.map(\.reason) == [.copyContentDrift])
    }

    @Test("distinguishes replaced Copy roots and target directories")
    func replacementIdentityDrift() async throws {
        for replaceRoot in [false, true] {
            let fixture = try await CopyDeletionFixture()
            let root = fixture.copyURL.deletingLastPathComponent()
            try FileManager.default.removeItem(
                at: replaceRoot ? root : fixture.copyURL
            )
            try FileManager.default.createDirectory(
                at: fixture.copyURL,
                withIntermediateDirectories: true
            )
            try Data("copy-recoverable".utf8).write(
                to: fixture.copyURL.appendingPathComponent("SKILL.md")
            )
            let selection = try await fixture.writer.loadDistributionSelection(
                skillID: fixture.skillID
            )
            let slug = try #require(
                selection.bindings.first?.distributionSlug
            )
            let plan = try await fixture.writer.distributionPlan(
                skillID: fixture.skillID,
                desiredConfiguration: .init(
                    scope: .global(slug),
                    syncMode: .copy
                ),
                requiredAdapterCodes: Set(
                    DistributionTargetCatalog.current.globalReaders
                        .map(\.storageKey)
                )
            )
            #expect(plan.status == .blocked)
            #expect(plan.conflicts.map(\.reason) == [
                replaceRoot ? .copyRootReplaced : .copyTargetReplaced
            ])
        }
    }

    @Test("moves Copy distribution between global and dedicated Agent targets")
    func convertsDistributionScope() async throws {
        let fixture = try await CopyDeletionFixture()
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        let slug = try #require(selection.bindings.first?.distributionSlug)
        let agents: Set<SkillPlatform> = [.codex, .claude]
        let toAgents = try await fixture.writer.distributionPlan(
            skillID: fixture.skillID,
            desiredConfiguration: .init(
                scope: .agents(agents, slug),
                syncMode: .copy
            ),
            requiredAdapterCodes: Set(agents.map(\.storageKey))
        )
        _ = try await fixture.writer.applyDistribution(
            skillID: fixture.skillID,
            plan: toAgents
        )

        #expect(!FileManager.default.fileExists(atPath: fixture.copyURL.path))
        for agent in agents {
            #expect(FileManager.default.fileExists(
                atPath: try fixture.distributionURL(for: .agent(agent), slug: slug).path
            ))
        }
        #expect(try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        ).bindings.count == agents.count)

        let toGlobal = try await fixture.writer.distributionPlan(
            skillID: fixture.skillID,
            desiredConfiguration: .init(scope: .global(slug), syncMode: .copy),
            requiredAdapterCodes: Set(
                DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
            )
        )
        _ = try await fixture.writer.applyDistribution(
            skillID: fixture.skillID,
            plan: toGlobal
        )
        #expect(FileManager.default.fileExists(atPath: fixture.copyURL.path))
        for agent in agents {
            #expect(!FileManager.default.fileExists(
                atPath: try fixture.distributionURL(for: .agent(agent), slug: slug).path
            ))
        }
    }

    @Test("deletes and restores Copy distribution with a fresh baseline")
    func deletesAndRestoresCopyDistribution() async throws {
        let fixture = try await CopyDeletionFixture()
        let before = try #require(
            try await fixture.writer.loadDistributionSelection(
                skillID: fixture.skillID
            ).bindings.first?.copyBaseline
        )

        let preview = try await fixture.writer.deletionPreview(
            skillID: fixture.skillID
        )
        _ = try await fixture.writer.deleteManagedSkill(preview: preview)
        #expect(try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        ).bindings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.copyURL.path))

        let backup = try await fixture.writer.listBackups(
            originalSkillID: fixture.skillID
        )[0]
        let restorePreview = try await fixture.writer.restorePreview(
            backup.backupID
        )
        let restored = try await fixture.writer.restoreBackup(
            preview: restorePreview,
            restoreDistribution: true
        )
        #expect(restored.status == .completed)
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: restored.restoredSkillID
        )
        let after = try #require(selection.bindings.first?.copyBaseline)
        #expect(selection.bindings.first?.syncMode == .copy)
        #expect(after.appliedOperationID != before.appliedOperationID)
        #expect(FileManager.default.fileExists(atPath: fixture.copyURL.path))
    }

    @Test("refuses deletion when Copy has physical drift")
    func refusesDriftedCopyDeletion() async throws {
        let fixture = try await CopyDeletionFixture()
        try Data("finder".utf8).write(
            to: fixture.copyURL.appendingPathComponent(".DS_Store")
        )

        await #expect(throws: SkillDeletionError.conflict) {
            _ = try await fixture.writer.deletionPreview(
                skillID: fixture.skillID
            )
        }
        #expect(try await fixture.writer.storedDomainReadback(
            fixture.skillID
        ) != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.copyURL.path))
    }
}

private struct CopyDeletionFixture {
    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let skillID: SkillID
    let copyURL: URL

    init() async throws {
        workspace = try WriterWorkspace(distributionEnabled: true)
        writer = try await workspace.openWriter()
        let snapshot = try workspace.snapshot(content: "copy-recoverable")
        skillID = SkillID()
        let payload = try workspace.payload(
            skillID: skillID,
            name: "CopyRecoverable",
            snapshot: snapshot
        )
        copyURL = workspace.distributionHomeURL
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(
                payload.skill.defaultDistributionSlug.value,
                isDirectory: true
            )
        _ = try await writer.create(
            payload: payload,
            sourceSnapshot: snapshot
        )
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: DistributionDesiredConfiguration(
                scope: .global(payload.skill.defaultDistributionSlug),
                syncMode: .copy
            ),
            requiredAdapterCodes: Set(
                DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
            )
        )
        _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
    }

    func distributionURL(
        for scope: DistributionBindingScope,
        slug: DefaultDistributionSlug
    ) throws -> URL {
        let target = try #require(
            DistributionTargetCatalog.current.target(for: scope)
        )
        return workspace.distributionHomeURL
            .appendingPathComponent(
                String(target.rootLocator.dropFirst(2)),
                isDirectory: true
            )
            .appendingPathComponent(slug.value, isDirectory: true)
    }
}
