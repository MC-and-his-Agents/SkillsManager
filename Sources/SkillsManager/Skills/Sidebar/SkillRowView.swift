import SwiftUI

struct SkillRowView: View {
    @Environment(SkillUpdateBadgeStore.self) private var badgeStore

    let skill: Skill

    private var statusIcon: String {
        skill.managedStatus == .needsRepair ? "exclamationmark.triangle" : "checkmark.seal"
    }

    private var statusTint: Color {
        skill.managedStatus == .needsRepair ? .orange : .green
    }

    private var statusText: String {
        skill.managedStatus == .needsRepair ? "Needs Attention" : "Managed"
    }

    private var rowBadge: SkillRowBadge? {
        let badge = badgeStore.badge(for: skill)
        switch badge {
        case .updateAvailable(let version):
            return .updateAvailable(version: version)
        case .needsAttention:
            return .needsAttention
        case .upToDate, .none:
            return nil
        }
    }

    private var badgeAccessibilityText: String? {
        switch rowBadge {
        case .updateAvailable(let version):
            "Update available, version \(version)"
        case .needsAttention:
            "Needs Repair"
        case nil:
            nil
        }
    }

    var body: some View {
        let badgeText = badgeAccessibilityText
        let labelParts: [String] = [
            skill.displayName,
            statusText,
            skill.listOrigin.labels.map(\.text).joined(separator: ", "),
            SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
            badgeText,
        ].compactMap { $0 }
        let valueParts: [String] = [
            statusText,
            skill.listOrigin.labels.map(\.text).joined(separator: ", "),
            SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
            badgeText,
        ].compactMap { $0 }
        return SkillListRow(
            data: SkillListRowData(
                id: skill.id,
                title: skill.displayName,
                detail: skill.description,
                statusIcon: statusIcon,
                statusTint: statusTint,
                sources: skill.listOrigin.labels,
                agentCount: skill.enabledPlatforms.count,
                accessibilityLabel: labelParts.joined(separator: ", "),
                accessibilityValue: valueParts.joined(separator: ", ")
            ),
            badge: rowBadge
        )
    }
}
