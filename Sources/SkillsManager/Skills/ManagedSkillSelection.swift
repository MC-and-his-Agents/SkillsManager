struct ManagedSkillSelection: Equatable, Sendable {
    let skillID: SkillID
    let displayName: String
}

@MainActor
func refreshManagedSkillSelection(
    _ selection: ManagedSkillSelection?,
    distributionModel: SkillDistributionViewModel,
    lifecycleModel: SkillLifecycleViewModel,
    isCurrent: @MainActor () -> Bool,
    preserveFeedback: Bool = false
) async {
    await distributionModel.refreshPreservingFeedback(
        skillID: selection?.skillID,
        displayName: selection?.displayName
    )
    guard isCurrent() else { return }
    if preserveFeedback {
        await lifecycleModel.refreshPreservingFeedback(skillID: selection?.skillID)
    } else {
        await lifecycleModel.refresh(skillID: selection?.skillID)
    }
}
