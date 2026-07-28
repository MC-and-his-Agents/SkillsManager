struct ManagedSkillSelection: Equatable, Sendable {
    let skillID: SkillID
    let displayName: String

    static func resolve(
        source: SkillSource,
        local: Self?,
        discovery: Self?
    ) -> Self? {
        switch source {
        case .local: local
        case .discovery: discovery
        case .clawdhub: nil
        }
    }
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
