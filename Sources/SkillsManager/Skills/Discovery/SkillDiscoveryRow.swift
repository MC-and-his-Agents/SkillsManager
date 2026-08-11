import SwiftUI

struct SkillDiscoveryRow: View {
    let item: SkillDiscoveryViewModel.Item

    var body: some View {
        let observation = item.observation
        SkillListRow(data: SkillListRowData(
            id: "\(item.id.relativeLocatorKey):\(item.id.rawRelativeLocator)",
            title: observation.displayName,
            detail: observation.scopes.map(\.localizedDisplayName).sorted().joined(separator: ", "),
            statusIcon: observation.status.systemImage,
            statusTint: observation.status.tint,
            sources: observation.listOrigin.labels,
            agentCount: 0,
            accessibilityLabel: observation.displayName,
            accessibilityValue: [
                localizedStatus(observation.status),
                String(localized: "On This Mac", bundle: SkillsManagerLocalizationResources.bundle),
                observation.listOrigin.labels.map(localizedSource).joined(separator: ", "),
                SkillListAgentSummary.text(count: 0),
            ].compactMap { $0 }.joined(separator: ", ")
        ))
        .help(observation.displayURLs.first?.path ?? observation.relativeLocator)
    }

    private func localizedStatus(_ status: SkillDiscoveryStatus) -> String {
        switch status {
        case .managed: String(localized: "Managed", bundle: SkillsManagerLocalizationResources.bundle)
        case .claimable: String(localized: "Ready to claim", bundle: SkillsManagerLocalizationResources.bundle)
        case .unmanaged: String(localized: "Unmanaged", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Conflict", bundle: SkillsManagerLocalizationResources.bundle)
        case .permissionDenied: String(localized: "Permission denied", bundle: SkillsManagerLocalizationResources.bundle)
        case .damaged: String(localized: "Damaged", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func localizedSource(_ label: SkillListSourceLabel) -> String {
        guard let source = label.knownSource else { return label.text }
        switch source {
        case .local: return String(localized: "Local", bundle: SkillsManagerLocalizationResources.bundle)
        case .repository: return String(localized: "Repository", bundle: SkillsManagerLocalizationResources.bundle)
        case .clawHub: return String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
        case .skillsSh: return String(localized: "skills.sh", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}
