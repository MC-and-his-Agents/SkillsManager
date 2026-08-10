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

    var body: some View {
        let badgeText = rowBadge.map { Self.localizedBadgeAccessibilityText($0) }
        let labelParts: [String] = [
            skill.displayName,
            localized(statusText),
            skill.listOrigin.labels.map { localized($0.text) }.joined(separator: ", "),
            SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
            badgeText,
        ].compactMap { $0 }
        let valueParts: [String] = [
            localized(statusText),
            skill.listOrigin.labels.map { localized($0.text) }.joined(separator: ", "),
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

    static func localizedBadgeAccessibilityText(
        _ badge: SkillRowBadge,
        locale: Locale? = nil
    ) -> String {
        switch badge {
        case .updateAvailable(let version):
            let resource = LocalizedStringResource(
                "Update available, version %arg",
                defaultValue: "Update available, version %arg",
                locale: locale ?? .current,
                bundle: .module
            )
            return String(localized: resource).replacingOccurrences(of: "%arg", with: version)
        case .needsAttention:
            let resource = LocalizedStringResource(
                "Needs Repair",
                defaultValue: "Needs Repair",
                locale: locale ?? .current,
                bundle: .module
            )
            return String(localized: resource)
        }
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
