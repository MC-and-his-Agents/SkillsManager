import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill distribution Copy decisions")
struct SkillDistributionViewModelTestsCopyDecisions {
    @Test("persisted Copy mode is editable and included in planning")
    @MainActor
    func copyModeSelection() async throws {
        let fixture = try decisionFixture()
        let probe = DistributionConfigurationProbe()
        let lineage = SkillForkLineageReadback(
            parentSkillID: SkillID(),
            parentDisplayName: nil,
            createdAtMilliseconds: 12,
            forkedFromFingerprint: try #require(
                fixture.selection.bindings.first?.copyBaseline?.contentFingerprint
            )
        )
        let model = SkillDistributionViewModel()
        model.activate(dependencies: SkillDistributionDependencies(
            loadSelection: { _ in fixture.selection },
            reconcile: { _ in fixture.reconcile },
            plan: { _, configuration, _ in
                await probe.record(configuration)
                return distributionPlan(status: .noOp)
            },
            apply: { skillID, _ in distributionOperation(skillID: skillID) },
            loadForkLineage: { _ in lineage }
        ))

        await model.refresh(skillID: fixture.skillID, displayName: "demo")
        #expect(model.currentSyncMode == .copy)
        #expect(model.selectedSyncMode == .copy)
        #expect(!model.hasUnappliedDraft)
        #expect(model.forkLineage?.parentSkillID == lineage.parentSkillID)
        #expect(model.forkLineage?.parentDisplayName == nil)

        model.setSyncMode(.symlink)
        #expect(model.hasUnappliedDraft)
        await model.preparePreview()
        #expect(await probe.lastMode == .symlink)
    }

    @Test("content drift offers explicit discard, Fork, and cancel decisions")
    @MainActor
    func contentDriftDecisions() async throws {
        let fixture = try decisionFixture()
        let probe = CopyDecisionProbe()
        let model = decisionModel(fixture: fixture, probe: probe)

        await model.refresh(skillID: fixture.skillID, displayName: "demo")
        await model.preparePreview()
        let pending = try #require(model.pendingPreview)
        let decision = try #require(pending.driftDecisions.first)
        #expect(pending.plan.status == .blocked)

        model.cancelPreview()
        #expect(await probe.discardCount == 0)
        #expect(await probe.forkCount == 0)

        await model.preparePreview()
        let discard = try #require(model.pendingPreview?.driftDecisions.first)
        await model.discardLocalChanges(discard)
        #expect(await probe.discardCount == 1)
        #expect(model.successMessage?.contains("discarded") == true)

        await model.preparePreview()
        let fork = try #require(model.pendingPreview?.driftDecisions.first)
        await model.keepAsFork(fork)
        #expect(await probe.forkCount == 1)
        #expect(model.requestedForkChildSkillID == fixture.preview.forkPreview.childSkillID)
        #expect(model.publishedForkSelectionGeneration == 1)
        _ = decision
    }

    @Test("stale decision fails closed without success")
    @MainActor
    func staleDecision() async throws {
        let fixture = try decisionFixture()
        let probe = CopyDecisionProbe(discardError: .previewExpired)
        let model = decisionModel(fixture: fixture, probe: probe)

        await model.refresh(skillID: fixture.skillID, displayName: "demo")
        await model.preparePreview()
        let decision = try #require(model.pendingPreview?.driftDecisions.first)
        await model.discardLocalChanges(decision)

        #expect(model.problem == .previewExpired)
        #expect(model.successMessage == nil)
    }
}

private actor DistributionConfigurationProbe {
    private(set) var lastMode: DistributionSyncMode?

    func record(_ configuration: DistributionDesiredConfiguration) {
        lastMode = configuration.syncMode
    }
}

private actor CopyDecisionProbe {
    private(set) var discardCount = 0
    private(set) var forkCount = 0
    private let discardError: CopyForkError?

    init(discardError: CopyForkError? = nil) {
        self.discardError = discardError
    }

    func discard(
        _ preview: CopyDriftDecisionPreview
    ) throws -> DistributionOperationRecord {
        discardCount += 1
        if let discardError { throw discardError }
        return distributionOperation(skillID: preview.forkPreview.parentSkillID)
    }

    func fork(_ preview: CopyDriftDecisionPreview) -> CopyForkResult {
        forkCount += 1
        return CopyForkResult(
            operationID: preview.forkPreview.operationID,
            parentSkillID: preview.forkPreview.parentSkillID,
            childSkillID: preview.forkPreview.childSkillID,
            scope: preview.forkPreview.scope
        )
    }
}

private struct DistributionDecisionFixture: Sendable {
    let skillID: SkillID
    let selection: DistributionSelectionReadback
    let reconcile: DistributionReconcileResult
    let plan: DistributionPlan
    let preview: CopyDriftDecisionPreview
}

@MainActor
private func decisionModel(
    fixture: DistributionDecisionFixture,
    probe: CopyDecisionProbe
) -> SkillDistributionViewModel {
    let model = SkillDistributionViewModel()
    model.activate(dependencies: SkillDistributionDependencies(
        loadSelection: { _ in fixture.selection },
        reconcile: { _ in fixture.reconcile },
        plan: { _, _, _ in fixture.plan },
        apply: { skillID, _ in distributionOperation(skillID: skillID) },
        copyDriftPreview: { _, _ in fixture.preview },
        discardCopyDrift: { try await probe.discard($0) },
        createCopyFork: { await probe.fork($0) }
    ))
    return model
}

private func decisionFixture() throws -> DistributionDecisionFixture {
    let skillID = distributionSkillID()
    let slug = try DefaultDistributionSlug(validating: "demo")
    var metadata = stat()
    metadata.st_mode = mode_t(S_IFDIR | 0o700)
    let identity = ManagedItemIdentity(metadata)
    let baseline = try DistributionCopyBaseline(
        contentFingerprint: SkillContentFingerprint(
            currentDigest: Data(repeating: 1, count: 32)
        ),
        physicalTreeDigest: CopyPhysicalTreeDigest(
            digest: Data(repeating: 2, count: 32)
        ),
        rootIdentity: identity,
        entryIdentity: identity,
        appliedOperationID: SSOTOperationID(),
        verifiedAtMilliseconds: 9
    )
    let binding = try DistributionBinding(
        skillID: skillID,
        scope: .global,
        distributionSlug: slug,
        syncMode: .copy,
        copyBaseline: baseline,
        createdAtMilliseconds: 10,
        updatedAtMilliseconds: 11
    )
    let observed = DistributionCopyEvidence(
        rootIdentity: identity,
        entryIdentity: identity,
        contentFingerprint: try SkillContentFingerprint(
            currentDigest: Data(repeating: 3, count: 32)
        ),
        physicalTreeDigest: baseline.physicalTreeDigest
    )
    let entry = try #require(DistributionTargetCatalog.current.entry(
        for: .global,
        slug: slug
    ))
    let conflict = DistributionPlanConflict(
        reason: .copyContentDrift,
        targetScopeKey: "global",
        targetRank: 0,
        slugKey: slug.collisionKey,
        canonicalLocator: entry.canonicalLocator
    )
    let fork = CopyForkPreview(
        operationID: SSOTOperationID(),
        parentSkillID: skillID,
        childSkillID: SkillID(),
        scope: .global,
        distributionSlug: slug,
        contentFingerprint: observed.contentFingerprint,
        token: Data("decision".utf8)
    )
    return DistributionDecisionFixture(
        skillID: skillID,
        selection: DistributionSelectionReadback(
            bindings: [binding],
            isExplicitlyConfigured: true
        ),
        reconcile: DistributionReconcileResult(
            status: .drifted,
            observations: [:]
        ),
        plan: distributionPlan(
            status: .blocked,
            replacement: [binding.intent],
            conflicts: [conflict]
        ),
        preview: CopyDriftDecisionPreview(
            parentRevision: 0,
            binding: binding,
            observedEvidence: observed,
            forkPreview: fork
        )
    )
}
