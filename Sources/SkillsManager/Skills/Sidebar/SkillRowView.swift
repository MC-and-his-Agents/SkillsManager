import SwiftUI

struct SkillRowView: View {
    let skill: Skill

    private var visibleSources: [SkillListSourceLabel] {
        Array(skill.listOrigin.labels.prefix(2))
    }

    private var sourceOverflowCount: Int {
        max(skill.listOrigin.labels.count - visibleSources.count, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.displayName)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(skill.identitySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(skill.identitySummary)

            Text(skill.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                TagView(
                    text: skill.managedStatus == .needsRepair ? "Needs Attention" : "Managed",
                    systemImage: skill.managedStatus == .needsRepair
                        ? "exclamationmark.triangle"
                        : "checkmark.seal"
                )

                ForEach(visibleSources) { source in
                    TagView(text: source.text, systemImage: source.systemImage)
                }

                if sourceOverflowCount > 0 {
                    TagView(text: "+\(sourceOverflowCount) sources")
                }

                TagView(
                    text: SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([
            skill.displayName,
            skill.identitySummary,
            skill.managedStatus == .needsRepair ? "Needs Attention" : "Managed",
            skill.listOrigin.labels.map(\.text).joined(separator: ", "),
            SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
        ].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue([
            skill.identitySummary,
            skill.managedStatus == .needsRepair ? "Needs Attention" : "Managed",
            skill.listOrigin.labels.map(\.text).joined(separator: ", "),
            SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
        ].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
