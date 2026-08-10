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
                String(localized: "On This Mac", bundle: .module),
                observation.listOrigin.labels.map(localizedSource).joined(separator: ", "),
                SkillListAgentSummary.text(count: 0),
            ].compactMap { $0 }.joined(separator: ", ")
        ))
        .help(observation.displayURLs.first?.path ?? observation.relativeLocator)
    }

    private func localizedStatus(_ status: SkillDiscoveryStatus) -> String {
        switch status {
        case .managed: String(localized: "Managed", bundle: .module)
        case .claimable: String(localized: "Ready to claim", bundle: .module)
        case .unmanaged: String(localized: "Unmanaged", bundle: .module)
        case .conflict: String(localized: "Conflict", bundle: .module)
        case .permissionDenied: String(localized: "Permission denied", bundle: .module)
        case .damaged: String(localized: "Damaged", bundle: .module)
        }
    }

    private func localizedSource(_ label: SkillListSourceLabel) -> String {
        guard let source = label.knownSource else { return label.text }
        switch source {
        case .local: return String(localized: "Local", bundle: .module)
        case .repository: return String(localized: "Repository", bundle: .module)
        case .clawHub: return String(localized: "ClawHub", bundle: .module)
        case .skillsSh: return String(localized: "skills.sh", bundle: .module)
        }
    }
}
