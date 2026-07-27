import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill distribution view model")
struct SkillDistributionViewModelTests {
    @Test("runtime blocks until dependencies are available")
    @MainActor
    func runtimeBlocked() async {
        let model = SkillDistributionViewModel()
        await model.refresh(skillID: distributionSkillID(), displayName: "Demo")
        #expect(model.loadState == .blocked("Preparing the managed library…"))
        #expect(!model.canPreparePreview)
    }

    @Test("empty bindings default to global symlink distribution")
    @MainActor
    func defaultGlobalScope() async {
        let model = distributionModel()
        await model.refresh(skillID: distributionSkillID(), displayName: "Demo")
        #expect(model.loadState == .ready(.notConfigured))
        #expect(model.scopeChoice == .global)
        #expect(model.selectedAgents.isEmpty)
        #expect(model.distributionSlug?.value == "Demo")
        #expect(model.currentTargets.isEmpty)
    }

    @Test("persisted Agent bindings restore scope and reject inconsistent slugs")
    @MainActor
    func persistedAgentScopeAndInvalidSlug() async throws {
        let skillID = distributionSkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let bindings = [
            try distributionBinding(skillID: skillID, scope: .agent(.codex), slug: slug),
            try distributionBinding(skillID: skillID, scope: .agent(.claude), slug: slug),
        ]
        let model = distributionModel(bindings: bindings)
        await model.refresh(skillID: skillID, displayName: "Demo")

        #expect(model.loadState == .ready(.inSync))
        #expect(model.scopeChoice == .agents)
        #expect(model.selectedAgents == [.codex, .claude])
        #expect(model.currentTargets.count == 2)

        let otherSlug = try DefaultDistributionSlug(validating: "other")
        let invalid = distributionModel(bindings: [
            bindings[0],
            try distributionBinding(skillID: skillID, scope: .agent(.claude), slug: otherSlug),
        ])
        await invalid.refresh(skillID: skillID, displayName: "Demo")
        #expect(invalid.loadState == .failed(.invalidPersistedBindings))
        #expect(!invalid.canPreparePreview)
    }

    @Test("Agent-specific scope requires at least one Agent")
    @MainActor
    func requiresAgentSelection() async {
        let model = distributionModel()
        await model.refresh(skillID: distributionSkillID(), displayName: "Demo")

        model.chooseScope(.agents)
        await model.preparePreview()
        #expect(model.problem == .invalidSelection)
        #expect(model.pendingPreview == nil)
    }

    @Test("preview distinguishes executable, no-op, and blocked plans")
    @MainActor
    func previewStates() async throws {
        let skillID = distributionSkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let executable = distributionPlan(
            status: .executable,
            replacement: [
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: .global,
                    distributionSlug: slug
                ),
            ]
        )
        let executableModel = distributionModel(plan: executable)
        await executableModel.refresh(skillID: skillID, displayName: "demo")
        await executableModel.preparePreview()
        #expect(executableModel.pendingPreview?.plan.status == .executable)
        #expect(executableModel.pendingPreview?.rows.map(\.kind) == [.binding])

        let noOpModel = distributionModel(plan: distributionPlan(status: .noOp))
        await noOpModel.refresh(skillID: skillID, displayName: "demo")
        await noOpModel.preparePreview()
        #expect(noOpModel.pendingPreview?.plan.status == .noOp)

        let conflict = DistributionPlanConflict(
            reason: .targetUnavailable,
            targetScopeKey: "global",
            targetRank: 0,
            slugKey: slug.collisionKey,
            canonicalLocator: "~/.agents/skills/demo"
        )
        let blockedModel = distributionModel(
            plan: distributionPlan(status: .blocked, conflicts: [conflict])
        )
        await blockedModel.refresh(skillID: skillID, displayName: "demo")
        await blockedModel.preparePreview()
        #expect(blockedModel.pendingPreview?.plan.status == .blocked)
        #expect(blockedModel.pendingPreview?.plan.conflicts.map(\.reason) == [.targetUnavailable])
    }

    @Test("partial scope preview includes retained targets")
    @MainActor
    func partialScopePreview() async throws {
        let skillID = distributionSkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let current = try distributionBinding(
            skillID: skillID,
            scope: .agent(.codex),
            slug: slug
        )
        let added = DistributionBindingIntent(
            skillID: skillID,
            scope: .agent(.opencode),
            distributionSlug: slug
        )
        let entry = try #require(
            DistributionTargetCatalog.current.entry(for: added.scope, slug: slug)
        )
        let plan = distributionPlan(
            status: .executable,
            actions: [
                DistributionFilesystemAction(
                    kind: .createSymlink,
                    entry: entry,
                    ssotLocator: DistributionTargetCatalog.current.ssotLocator(for: skillID)
                ),
            ],
            replacement: [current.intent, added]
        )
        let model = distributionModel(bindings: [current], plan: plan)
        await model.refresh(skillID: skillID, displayName: "demo")

        model.chooseScope(.agents)
        model.setAgent(.codex, selected: true)
        model.setAgent(.opencode, selected: true)
        await model.preparePreview()

        #expect(model.pendingPreview?.rows.map(\.kind) == [.create, .noChange])
        #expect(model.pendingPreview?.rows.map(\.scopeKey) == [
            "agent:opencode",
            "agent:codex",
        ])
    }

    @Test("partial scope preview includes binding-only additions")
    @MainActor
    func partialScopeBindingOnlyPreview() async throws {
        let skillID = distributionSkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let current = try distributionBinding(skillID: skillID, scope: .agent(.codex), slug: slug)
        let added = DistributionBindingIntent(
            skillID: skillID, scope: .agent(.opencode), distributionSlug: slug
        )
        let plan = distributionPlan(status: .executable, replacement: [current.intent, added])
        let model = distributionModel(bindings: [current], plan: plan)
        await model.refresh(skillID: skillID, displayName: "demo")

        model.chooseScope(.agents)
        model.setAgent(.codex, selected: true)
        model.setAgent(.opencode, selected: true)
        await model.preparePreview()

        #expect(model.pendingPreview?.rows.map(\.kind) == [.noChange, .binding])
        #expect(model.pendingPreview?.rows.map(\.scopeKey) == [
            "agent:codex",
            "agent:opencode",
        ])
    }

    @Test("confirmation rejects a changed canonical plan without applying")
    @MainActor
    func stalePreview() async throws {
        let skillID = distributionSkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let first = distributionPlan(
            status: .executable,
            replacement: [
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: .global,
                    distributionSlug: slug
                ),
            ]
        )
        let second = distributionPlan(
            status: .executable,
            replacement: [
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: .agent(.codex),
                    distributionSlug: slug
                ),
            ]
        )
        let probe = DistributionPlanProbe(plans: [first, second])
        let model = distributionModel(probe: probe)
        await model.refresh(skillID: skillID, displayName: "demo")
        await model.preparePreview()
        await model.confirmPreview()
        #expect(model.problem == .previewExpired)
        #expect(model.pendingPreview == nil)
        #expect(await probe.applyCount == 0)
    }

    @Test("selection change during replan prevents apply")
    @MainActor
    func selectionChangeDuringConfirmation() async throws {
        let firstID = distributionSkillID()
        let secondID = SkillID(UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!)
        let slug = try DefaultDistributionSlug(validating: "demo")
        let plan = distributionPlan(
            status: .executable,
            replacement: [
                DistributionBindingIntent(
                    skillID: firstID,
                    scope: .global,
                    distributionSlug: slug
                ),
            ]
        )
        let probe = DistributionPlanProbe(
            plans: [plan],
            replanDelay: .milliseconds(30)
        )
        let model = distributionModel(probe: probe)
        await model.refresh(skillID: firstID, displayName: "demo")
        await model.preparePreview()

        let confirmation = Task { await model.confirmPreview() }
        while await probe.planCallCount < 2 {
            await Task.yield()
        }
        await model.refresh(skillID: secondID, displayName: "second")
        await confirmation.value

        #expect(await probe.applyCount == 0)
        #expect(model.activeSkillID == secondID)
        #expect(model.problem == nil)
        #expect(!model.isApplying)
    }

    @Test("slow preview failure cannot overwrite a new selection")
    @MainActor
    func stalePreviewFailure() async {
        let firstID = distributionSkillID()
        let secondID = SkillID(UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!)
        let probe = DistributionPlanProbe(
            plans: [distributionPlan(status: .noOp)],
            initialPlanDelay: .milliseconds(30),
            planError: .unavailable
        )
        let model = distributionModel(probe: probe)
        await model.refresh(skillID: firstID, displayName: "first")

        let preparation = Task { await model.preparePreview() }
        while await probe.planCallCount < 1 {
            await Task.yield()
        }
        await model.refresh(skillID: secondID, displayName: "second")
        await preparation.value

        #expect(model.activeSkillID == secondID)
        #expect(model.problem == nil)
        #expect(model.pendingPreview == nil)
        #expect(!model.isPreparingPreview)
    }

    @Test("no-op skips apply and successful confirmation accepts one submit")
    @MainActor
    func noOpAndDuplicateConfirmation() async throws {
        let skillID = distributionSkillID()
        let noOpProbe = DistributionPlanProbe(plans: [distributionPlan(status: .noOp)])
        let noOpModel = distributionModel(probe: noOpProbe)
        await noOpModel.refresh(skillID: skillID, displayName: "demo")
        await noOpModel.preparePreview()
        await noOpModel.confirmPreview()
        #expect(await noOpProbe.applyCount == 0)
        #expect(noOpModel.successMessage == "No distribution changes were needed.")

        let slug = try DefaultDistributionSlug(validating: "demo")
        let plan = distributionPlan(
            status: .executable,
            replacement: [
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: .global,
                    distributionSlug: slug
                ),
            ]
        )
        let probe = DistributionPlanProbe(
            plans: [plan],
            applyRecord: distributionOperation(skillID: skillID),
            applyDelay: .milliseconds(40)
        )
        let model = distributionModel(probe: probe)
        await model.refresh(skillID: skillID, displayName: "demo")
        await model.preparePreview()

        let first = Task { await model.confirmPreview() }
        await Task.yield()
        #expect(model.isApplying)
        #expect(model.pendingPreview != nil)
        let duplicate = Task { await model.confirmPreview() }
        await first.value
        await duplicate.value

        #expect(await probe.applyCount == 1)
        #expect(model.successMessage == "Distribution completed and the current state was refreshed.")
        #expect(model.problem == nil)
    }

    @Test("non-applied terminal records and recovery states fail closed")
    @MainActor
    func terminalAndRecoveryStates() async throws {
        let skillID = distributionSkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let plan = distributionPlan(
            status: .executable,
            replacement: [
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: .global,
                    distributionSlug: slug
                ),
            ]
        )
        let operation = distributionOperation(
            skillID: skillID,
            phase: .completed,
            outcome: .rolledBack
        )
        let model = distributionModel(
            probe: DistributionPlanProbe(plans: [plan], applyRecord: operation)
        )
        await model.refresh(skillID: skillID, displayName: "demo")
        await model.preparePreview()
        await model.confirmPreview()
        #expect(model.problem == .operationDidNotComplete)

        for status in [
            DistributionReconcileStatus.needsRepair,
            .operationInProgress,
        ] {
            let blocked = distributionModel(reconcileStatus: status)
            await blocked.refresh(skillID: skillID, displayName: "demo")
            #expect(!blocked.canPreparePreview)
            if status == .needsRepair {
                #expect(blocked.loadState == .ready(.needsRepair))
            } else {
                #expect(blocked.loadState == .ready(.operationInProgress))
            }
        }
    }

    @Test("invalidated preview preparation always leaves the busy state")
    @MainActor
    func invalidatedPreparationEnds() async {
        let model = SkillDistributionViewModel()
        model.activate(dependencies: SkillDistributionDependencies(
            loadBindings: { _ in [] },
            reconcile: { _ in DistributionReconcileResult(status: .inSync, observations: [:]) },
            plan: { _, _, _ in
                try await Task.sleep(for: .milliseconds(30))
                return distributionPlan(status: .noOp)
            },
            apply: { skillID, _ in distributionOperation(skillID: skillID) }
        ))
        await model.refresh(skillID: distributionSkillID(), displayName: "demo")

        let preparation = Task { await model.preparePreview() }
        await Task.yield()
        await model.refresh(skillID: nil, displayName: nil)
        await preparation.value

        #expect(!model.isPreparingPreview)
        #expect(model.pendingPreview == nil)
        #expect(model.loadState == .empty)
    }

    @Test("executor repair and in-progress errors have stable presentation")
    @MainActor
    func executorErrors() async throws {
        let skillID = distributionSkillID()
        let slug = try DefaultDistributionSlug(validating: "demo")
        let plan = distributionPlan(
            status: .executable,
            replacement: [
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: .global,
                    distributionSlug: slug
                ),
            ]
        )
        let cases: [(SkillDistributionViewModel, SkillDistributionViewModel.Problem)] = [
            (
                distributionModel(
                    plan: plan,
                    apply: { _, _ in
                        throw DistributionSymlinkExecutorError.needsRepair("test")
                    }
                ),
                .needsRepair
            ),
            (
                distributionModel(
                    plan: plan,
                    apply: { _, _ in
                        throw DistributionSymlinkExecutorError.operationInProgress
                    }
                ),
                .operationInProgress
            ),
        ]

        for (model, expectedProblem) in cases {
            await model.refresh(skillID: skillID, displayName: "demo")
            await model.preparePreview()
            await model.confirmPreview()
            #expect(model.problem == expectedProblem)
        }
    }

    @Test("permission and unavailable errors have stable presentation")
    @MainActor
    func stableErrorMapping() async {
        let permission = distributionModel(loadError: .posix(operation: "open", code: EACCES))
        await permission.refresh(skillID: distributionSkillID(), displayName: "demo")
        #expect(permission.loadState == .failed(.permissionDenied))

        let unavailable = distributionModel(loadError: .unavailable)
        await unavailable.refresh(skillID: distributionSkillID(), displayName: "demo")
        #expect(unavailable.loadState == .failed(.targetUnavailable))
    }

    @Test("a slower previous selection cannot overwrite the current Skill")
    @MainActor
    func staleRefreshDoesNotPublish() async throws {
        let firstID = distributionSkillID()
        let secondID = SkillID(UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!)
        let firstSlug = try DefaultDistributionSlug(validating: "first")
        let secondSlug = try DefaultDistributionSlug(validating: "second")
        let dependencies = SkillDistributionDependencies(
            loadBindings: { skillID in
                if skillID == firstID {
                    try await Task.sleep(for: .milliseconds(60))
                    return [try distributionBinding(skillID: firstID, scope: .global, slug: firstSlug)]
                }
                return [try distributionBinding(skillID: secondID, scope: .global, slug: secondSlug)]
            },
            reconcile: { _ in
                DistributionReconcileResult(status: .inSync, observations: [:])
            },
            plan: { _, _, _ in distributionPlan(status: .noOp) },
            apply: { skillID, _ in distributionOperation(skillID: skillID) }
        )
        let model = SkillDistributionViewModel()
        model.activate(dependencies: dependencies)

        let stale = Task { await model.refresh(skillID: firstID, displayName: "first") }
        try await Task.sleep(for: .milliseconds(5))
        await model.refresh(skillID: secondID, displayName: "second")
        await stale.value

        #expect(model.activeSkillID == secondID)
        #expect(model.distributionSlug == secondSlug)
        #expect(model.activeDisplayName == "second")
    }

    @Test("manual refresh reloads the current Skill")
    @MainActor
    func manualRefresh() async {
        let probe = DistributionLoadProbe()
        let model = SkillDistributionViewModel()
        model.activate(dependencies: SkillDistributionDependencies(
            loadBindings: { _ in await probe.load() },
            reconcile: { _ in DistributionReconcileResult(status: .inSync, observations: [:]) },
            plan: { _, _, _ in distributionPlan(status: .noOp) },
            apply: { skillID, _ in distributionOperation(skillID: skillID) }
        ))

        await model.refresh(skillID: distributionSkillID(), displayName: "demo")
        await model.refreshCurrent()
        #expect(await probe.loadCount == 2)
        #expect(model.loadState == .ready(.notConfigured))
    }
}
