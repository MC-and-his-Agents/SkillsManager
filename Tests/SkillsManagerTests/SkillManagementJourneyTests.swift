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
}
