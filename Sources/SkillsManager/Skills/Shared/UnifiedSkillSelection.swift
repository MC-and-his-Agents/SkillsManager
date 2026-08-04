import Foundation

nonisolated enum UnifiedSkillSelection: Hashable, Sendable {
    case managed(Skill.ID)
    case discovered(SkillDiscoveryItemID)
    case repository(CustomRepositoryCandidateID)
    case clawHub(RemoteSkill.ID)
    case skillsSh(SkillsShSearchResultID)
}

nonisolated func normalizedSkillSearchQuery(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
}

nonisolated func visibleDiscoveryItems(
    _ items: [SkillDiscoveryViewModel.Item],
    managedSkillIDs: Set<SkillID>
) -> [SkillDiscoveryViewModel.Item] {
    items.filter { item in
        let observation = item.observation
        return observation.status != .managed
            || observation.matchedSkillID.map(managedSkillIDs.contains) != true
    }
}

nonisolated func reconciledSkillSelection(
    _ selection: UnifiedSkillSelection?,
    visibleSelections: Set<UnifiedSkillSelection>
) -> UnifiedSkillSelection? {
    selection.flatMap { visibleSelections.contains($0) ? $0 : nil }
}

nonisolated func visibleRemoteSkillSelections(
    clawHubSkills: [RemoteSkill],
    clawHubLoaded: Bool,
    skillsShItems: [SkillsShSearchItem] = [],
    skillsShLoaded: Bool = false
) -> Set<UnifiedSkillSelection> {
    var values = Set<UnifiedSkillSelection>()
    if clawHubLoaded {
        values.formUnion(clawHubSkills.map { .clawHub($0.id) })
    }
    if skillsShLoaded {
        values.formUnion(skillsShItems.map { .skillsSh(SkillsShSearchResultID($0)) })
    }
    return values
}
