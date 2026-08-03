import SwiftUI

struct SkillDiscoveryRow: View {
    let item: SkillDiscoveryViewModel.Item

    var body: some View {
        let observation = item.observation
        HStack(spacing: 10) {
            Image(systemName: observation.status.systemImage)
                .foregroundStyle(observation.status.tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(observation.displayName)
                    .lineLimit(1)
                Text("\(observation.status.displayName) · \(observation.scopeSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(observation.displayName)
        .accessibilityValue([
            observation.status.displayName,
            "On This Mac",
            observation.scopeSummary,
            observation.displayURLs.first?.path,
            observation.sourceSummary,
            observation.fingerprintSummary,
            observation.reason.map(\.displayName),
        ].compactMap { $0 }.joined(separator: ", "))
        .help(observation.displayURLs.first?.path ?? observation.relativeLocator)
    }
}
