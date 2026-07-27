import Testing

@testable import SkillsManager

@Suite("Skill management journey")
@MainActor
struct SkillManagementJourneyTests {
    @Test("management follows only the visible source")
    func visibleSourceSelection() {
        let local = ManagedSkillSelection(skillID: SkillID(), displayName: "Local")
        let discovery = ManagedSkillSelection(skillID: SkillID(), displayName: "Discovered")

        #expect(ManagedSkillSelection.resolve(
            source: .local,
            local: local,
            discovery: discovery
        ) == local)
        #expect(ManagedSkillSelection.resolve(
            source: .discovery,
            local: local,
            discovery: discovery
        ) == discovery)
        #expect(ManagedSkillSelection.resolve(
            source: .clawdhub,
            local: local,
            discovery: discovery
        ) == nil)
    }

    @Test("leaving a managed source clears distribution state")
    func sourceChangeClearsDistribution() async {
        let model = distributionModel()
        let selection = ManagedSkillSelection(
            skillID: distributionSkillID(),
            displayName: "Managed"
        )

        await model.refresh(skillID: selection.skillID, displayName: selection.displayName)
        #expect(model.loadState == .ready(.notConfigured))

        let cleared = ManagedSkillSelection.resolve(
            source: .clawdhub,
            local: selection,
            discovery: nil
        )
        await model.refresh(skillID: cleared?.skillID, displayName: cleared?.displayName)

        #expect(model.loadState == .empty)
        #expect(model.pendingPreview == nil)
        #expect(model.currentTargets.isEmpty)
    }

    @Test("a stale distribution refresh cannot retarget deletion")
    func staleDistributionCannotRetargetDeletion() async throws {
        let firstID = SkillID()
        let secondID = SkillID()
        let first = ManagedSkillSelection(skillID: firstID, displayName: "First")
        let second = ManagedSkillSelection(skillID: secondID, displayName: "Second")
        let secondPreview = try deletionPreview(
            skillID: secondID,
            displayName: "Second"
        )
        let distribution = SkillDistributionViewModel()
        distribution.activate(dependencies: SkillDistributionDependencies(
            loadSelection: { skillID in
                if skillID == firstID {
                    try await Task.sleep(for: .milliseconds(30))
                }
                return DistributionSelectionReadback(
                    bindings: [],
                    isExplicitlyConfigured: false
                )
            },
            reconcile: { _ in
                DistributionReconcileResult(status: .inSync, observations: [:])
            },
            plan: { _, _, _ in distributionPlan(status: .noOp) },
            apply: { skillID, _ in distributionOperation(skillID: skillID) }
        ))
        let lifecycle = SkillLifecycleViewModel()
        lifecycle.activate(dependencies: lifecycleDependencies(
            deletionPreview: { skillID in
                if skillID == secondID { return secondPreview }
                return try deletionPreview(skillID: skillID, displayName: "First")
            }
        ))

        var current: ManagedSkillSelection? = first
        let stale = Task {
            await refreshManagedSkillSelection(
                first,
                distributionModel: distribution,
                lifecycleModel: lifecycle,
                isCurrent: { current == first }
            )
        }
        try await Task.sleep(for: .milliseconds(5))
        current = second
        await refreshManagedSkillSelection(
            second,
            distributionModel: distribution,
            lifecycleModel: lifecycle,
            isCurrent: { current == second }
        )

        #expect(lifecycle.deletionState == .ready(secondPreview))

        current = nil
        await refreshManagedSkillSelection(
            nil,
            distributionModel: distribution,
            lifecycleModel: lifecycle,
            isCurrent: { current == nil }
        )
        await stale.value

        #expect(lifecycle.deletionState == .empty)
        #expect(distribution.loadState == .empty)
    }
}
