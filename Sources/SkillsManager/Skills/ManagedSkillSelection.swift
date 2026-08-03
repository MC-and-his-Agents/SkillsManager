struct ManagedSkillSelection: Equatable, Sendable {
    let skillID: SkillID
    let displayName: String
}

@MainActor
func refreshManagedSkillSelection(
    _ selection: ManagedSkillSelection?,
    distributionModel: SkillDistributionViewModel,
    lifecycleModel: SkillLifecycleViewModel,
    isCurrent: @MainActor () -> Bool
) async {
    await distributionModel.refresh(
        skillID: selection?.skillID,
        displayName: selection?.displayName
    )
    guard isCurrent() else { return }
    await lifecycleModel.refresh(skillID: selection?.skillID)
}
