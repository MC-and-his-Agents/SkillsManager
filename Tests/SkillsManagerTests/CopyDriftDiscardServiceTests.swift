import Foundation
import Testing

@testable import SkillsManager

@Suite("Copy drift discard service", .serialized)
struct CopyDriftDiscardServiceTests {
    @Test("explicit discard restores SSOT through an auditable action")
    func discardsContentOnlyDrift() async throws {
        let fixture = try await makeDiscardFixture()
        let preview = try await fixture.writer.copyDriftDecisionPreview(
            parentSkillID: fixture.skillID,
            scope: .global
        )
        let operation = try await fixture.writer.discardCopyDrift(preview)

        #expect(operation.phase == .completed)
        #expect(operation.outcome == .applied)
        #expect(operation.formatVersion == 2)
        #expect(try operation.planPayloadString().contains("discard_copy_drift"))
        #expect(try String(
            contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "original")
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        #expect(selection.bindings.count == 1)
        #expect(selection.bindings.first?.syncMode == .copy)
        #expect(
            selection.bindings.first?.copyBaseline?.appliedOperationID
                == operation.operationID
        )
    }

    @Test("ordinary apply cannot inject the explicit discard action")
    func ordinaryApplyRejectsDiscard() async throws {
        let fixture = try await makeDiscardFixture()
        let selection = try await fixture.writer.loadDistributionSelection(
            skillID: fixture.skillID
        )
        let binding = try #require(selection.bindings.first)
        let entry = try #require(DistributionTargetCatalog.current.entry(
            for: binding.scope,
            slug: binding.distributionSlug
        ))
        let plan = DistributionPlan(
            status: .executable,
            filesystemActions: [DistributionFilesystemAction(
                kind: .discardCopyDrift,
                entry: entry,
                ssotLocator: DistributionTargetCatalog.current.ssotLocator(
                    for: fixture.skillID
                )
            )],
            bindingsChanged: false,
            bindingReplacement: selection.bindings.map(\.intent),
            configurationChanged: false,
            expectedOldConfigured: selection.isExplicitlyConfigured,
            desiredConfigured: selection.isExplicitlyConfigured,
            conflicts: []
        )
        let operationCount = try fixture.workspace.integer(
            "SELECT count(*) FROM distribution_operations"
        )

        await #expect(throws: DistributionSymlinkExecutorError.conflict) {
            _ = try await fixture.writer.applyDistribution(
                skillID: fixture.skillID,
                plan: plan
            )
        }
        #expect(try fixture.workspace.integer(
            "SELECT count(*) FROM distribution_operations"
        ) == operationCount)
        #expect(try String(
            contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "locally changed")
    }

    @Test("stale decision evidence rejects discard and Fork without mutation")
    func staleDecisionEvidence() async throws {
        let fixture = try await makeDiscardFixture()
        let preview = try await fixture.writer.copyDriftDecisionPreview(
            parentSkillID: fixture.skillID,
            scope: .global
        )
        try Data("changed again".utf8).write(
            to: fixture.copyURL.appendingPathComponent("SKILL.md")
        )
        let operationCount = try fixture.workspace.integer(
            "SELECT count(*) FROM distribution_operations"
        )

        await #expect(throws: CopyForkError.previewExpired) {
            _ = try await fixture.writer.discardCopyDrift(preview)
        }
        await #expect(throws: CopyForkError.previewExpired) {
            _ = try await fixture.writer.createCopyFork(preview.forkPreview)
        }
        #expect(try fixture.workspace.integer(
            "SELECT count(*) FROM distribution_operations"
        ) == operationCount)
        #expect(try fixture.workspace.integer(
            "SELECT count(*) FROM copy_fork_operations"
        ) == 0)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skills") == 1)
    }

    @Test("SSOT changes expire both destructive decisions without mutation")
    func staleSSOTEvidence() async throws {
        let fixture = try await makeDiscardFixture()
        let preview = try await fixture.writer.copyDriftDecisionPreview(
            parentSkillID: fixture.skillID,
            scope: .global
        )
        let ssot = fixture.workspace.root.appendingPathComponent(
            fixture.skillID.directoryName,
            isDirectory: true
        )
        try Data("externally replaced".utf8).write(
            to: ssot.appendingPathComponent("SKILL.md")
        )
        let operationCount = try fixture.workspace.integer(
            "SELECT count(*) FROM distribution_operations"
        )

        await #expect(throws: CopyForkError.previewExpired) {
            _ = try await fixture.writer.discardCopyDrift(preview)
        }
        await #expect(throws: CopyForkError.previewExpired) {
            _ = try await fixture.writer.createCopyFork(preview)
        }
        #expect(try fixture.workspace.integer(
            "SELECT count(*) FROM distribution_operations"
        ) == operationCount)
        #expect(try fixture.workspace.integer(
            "SELECT count(*) FROM copy_fork_operations"
        ) == 0)
        #expect(try String(
            contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "locally changed")
    }

    @Test("Copy-Fork provenance uses format v3 and keeps the explicit action")
    func discardFromForkUsesV3() async throws {
        let fixture = try await makeDiscardFixture()
        let decision = try await fixture.writer.copyDriftDecisionPreview(
            parentSkillID: fixture.skillID,
            scope: .global
        )
        let fork = try await fixture.writer.createCopyFork(decision.forkPreview)
        try Data("second local edit".utf8).write(
            to: fixture.copyURL.appendingPathComponent("SKILL.md")
        )

        let forkDecision = try await fixture.writer.copyDriftDecisionPreview(
            parentSkillID: fork.childSkillID,
            scope: .global
        )
        let operation = try await fixture.writer.discardCopyDrift(forkDecision)

        #expect(operation.formatVersion == 3)
        #expect(try operation.planPayloadString().contains("discard_copy_drift"))
        #expect(try String(
            contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "locally changed")
    }
}

private struct CopyDriftDiscardFixture {
    let workspace: WriterWorkspace
    let writer: JournaledSSOTWriter
    let skillID: SkillID
    let copyURL: URL
}

private func makeDiscardFixture() async throws -> CopyDriftDiscardFixture {
    let workspace = try WriterWorkspace(distributionEnabled: true)
    let writer = try await workspace.openWriter()
    let skillID = try await prepareParentCopy(workspace: workspace, writer: writer)
    let slug = try DefaultDistributionSlug(validating: "parent")
    let copyURL = workspace.workspace
        .appendingPathComponent(".agents/skills", isDirectory: true)
        .appendingPathComponent(slug.value, isDirectory: true)
    try Data("locally changed".utf8).write(
        to: copyURL.appendingPathComponent("SKILL.md")
    )
    return CopyDriftDiscardFixture(
        workspace: workspace,
        writer: writer,
        skillID: skillID,
        copyURL: copyURL
    )
}

private extension DistributionOperationRecord {
    func planPayloadString() throws -> String {
        guard let value = String(data: planPayload, encoding: .utf8) else {
            throw DistributionOperationStoreError.invalidRecord
        }
        return value
    }
}
