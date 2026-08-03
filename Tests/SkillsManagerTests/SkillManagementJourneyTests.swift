import Testing

@testable import SkillsManager

@Suite("Skill management journey")
@MainActor
struct SkillManagementJourneyTests {
    @Test("managed discovery observations collapse into their canonical row")
    func canonicalManagedRows() {
        let managedID = SkillID()
        let otherID = SkillID()
        let items = [
            SkillDiscoveryViewModel.Item(discoveryTestObservation(
                name: "canonical",
                status: .managed,
                matchedSkillID: managedID
            )),
            SkillDiscoveryViewModel.Item(discoveryTestObservation(
                name: "same-name-different-id",
                status: .managed,
                matchedSkillID: otherID
            )),
            SkillDiscoveryViewModel.Item(discoveryTestObservation(
                name: "unmanaged",
                status: .unmanaged
            )),
        ]

        let visible = visibleDiscoveryItems(items, managedSkillIDs: [managedID])

        #expect(visible.map(\.observation.rawRelativeLocator) == [
            "same-name-different-id",
            "unmanaged",
        ])
    }

    @Test("search normalization and projection reconciliation clear hidden rows")
    func projectionReconciliation() {
        #expect(normalizedSkillSearchQuery("  \n\t") == "")
        #expect(normalizedSkillSearchQuery("  swift  ") == "swift")

        let latest = UnifiedSkillSelection.clawHub("latest")
        let searched = UnifiedSkillSelection.clawHub("searched")
        #expect(reconciledSkillSelection(
            latest,
            visibleSelections: [latest]
        ) == latest)
        #expect(reconciledSkillSelection(
            latest,
            visibleSelections: [searched]
        ) == nil)
        #expect(reconciledSkillSelection(
            nil,
            visibleSelections: [latest]
        ) == nil)
    }

    @Test("provider rows are selectable only while their section is visible")
    func providerStateProjection() {
        let skill = RemoteSkill(
            id: "latest",
            slug: "latest",
            displayName: "Latest",
            summary: nil,
            latestVersion: nil,
            updatedAt: nil,
            downloads: nil,
            stars: nil
        )
        let selected = UnifiedSkillSelection.clawHub(skill.id)

        #expect(visibleRemoteSkillSelections(
            clawHubSkills: [skill],
            clawHubLoaded: true
        ) == [selected])
        #expect(reconciledSkillSelection(
            selected,
            visibleSelections: visibleRemoteSkillSelections(
                clawHubSkills: [skill],
                clawHubLoaded: false
            )
        ) == nil)
    }

    @Test("clearing a managed selection clears distribution state")
    func clearingSelectionClearsDistribution() async {
        let model = distributionModel()
        let selection = ManagedSkillSelection(
            skillID: distributionSkillID(),
            displayName: "Managed"
        )

        await model.refresh(skillID: selection.skillID, displayName: selection.displayName)
        #expect(model.loadState == .ready(.notConfigured))

        await model.refresh(skillID: nil, displayName: nil)

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
