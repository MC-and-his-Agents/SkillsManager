import SwiftUI

struct SkillDiscoveryRow: View {
    let item: SkillDiscoveryViewModel.Item

    private var visibleSources: [SkillListSourceLabel] {
        Array(item.observation.listOrigin.labels.prefix(2))
    }

    private var sourceOverflowCount: Int {
        max(item.observation.listOrigin.labels.count - visibleSources.count, 0)
    }

    var body: some View {
        let observation = item.observation
        HStack(spacing: 10) {
            Image(systemName: observation.status.systemImage)
                .foregroundStyle(.primary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(observation.displayName)
                    .lineLimit(1)
                Text(observation.scopeSummary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    TagView(
                        text: observation.status.displayName,
                        systemImage: observation.status.systemImage,
                        tint: observation.status.tint
                    )
                    ForEach(visibleSources) { source in
                        TagView(text: source.text, systemImage: source.systemImage)
                    }
                    if sourceOverflowCount > 0 {
                        TagView(text: "+\(sourceOverflowCount) sources")
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(observation.displayName)
        .accessibilityValue([
            observation.status.displayName,
            "On This Mac",
            observation.listOrigin.labels.map(\.text).joined(separator: ", "),
            "0 Agents",
        ].compactMap { $0 }.joined(separator: ", "))
        .help(observation.displayURLs.first?.path ?? observation.relativeLocator)
    }
}
