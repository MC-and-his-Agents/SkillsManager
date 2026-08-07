import SwiftUI

struct SkillDiscoveryRow: View {
    let item: SkillDiscoveryViewModel.Item

    var body: some View {
        let observation = item.observation
        SkillListRow(data: SkillListRowData(
            id: "\(item.id.relativeLocatorKey):\(item.id.rawRelativeLocator)",
            title: observation.displayName,
            detail: observation.scopeSummary,
            statusIcon: observation.status.systemImage,
            statusTint: observation.status.tint,
            sources: observation.listOrigin.labels,
            agentCount: 0,
            accessibilityLabel: observation.displayName,
            accessibilityValue: [
                observation.status.displayName,
                "On This Mac",
                observation.listOrigin.labels.map(\.text).joined(separator: ", "),
                "0 Agents",
            ].compactMap { $0 }.joined(separator: ", ")
        ))
        .help(observation.displayURLs.first?.path ?? observation.relativeLocator)
    }
}
