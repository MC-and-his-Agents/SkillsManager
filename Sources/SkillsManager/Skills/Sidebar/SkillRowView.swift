import SwiftUI

struct SkillRowView: View {
    @Environment(SkillUpdateBadgeStore.self) private var badgeStore

    let skill: Skill

    private var statusIcon: String {
        skill.managedStatus == .needsRepair ? "exclamationmark.triangle" : "checkmark.seal"
    }

    private var statusTint: Color {
        skill.managedStatus == .needsRepair ? SkillStatusPalette.warning : SkillStatusPalette.healthy
    }

    private var statusText: String {
        switch skill.managedStatus {
        case .managed:
            String(localized: "Managed", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair:
            String(localized: "Needs Attention", bundle: SkillsManagerLocalizationResources.bundle)
        }
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
            statusText,
            skill.listOrigin.labels.map(sourceText).joined(separator: ", "),
            SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
            badgeText,
        ].compactMap { $0 }
        let valueParts: [String] = [
            statusText,
            skill.listOrigin.labels.map(sourceText).joined(separator: ", "),
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
        .task(id: badgeStore.refreshGeneration) {
            await badgeStore.checkIfNeeded(for: skill)
        }
    }

    static func localizedBadgeAccessibilityText(
        _ badge: SkillRowBadge,
        locale: Locale? = nil
    ) -> String {
        switch badge {
        case .updateAvailable(let version):
            return String(
                localized: LocalizedStringResource(
            "Update available, version \(version)",
            locale: locale ?? .current,
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        case .needsAttention:
            let resource = LocalizedStringResource(
            "Needs Repair",
            locale: locale ?? .current,
            bundle: SkillsManagerLocalizationResources.bundle
        )
            return String(localized: resource)
        }
    }

    private func sourceText(_ label: SkillListSourceLabel) -> String {
        guard let source = label.knownSource else { return label.text }
        switch source {
        case .local:
            return String(localized: "Local", bundle: SkillsManagerLocalizationResources.bundle)
        case .repository:
            return String(localized: "Repository", bundle: SkillsManagerLocalizationResources.bundle)
        case .clawHub:
            return String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
        case .skillsSh:
            return String(localized: "skills.sh", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}
