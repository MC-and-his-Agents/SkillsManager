import SwiftUI

struct RemoteSkillRowView: View {
    let skill: RemoteSkill
    let installedTargets: Set<SkillPlatform>
    let onInstall: () -> Void

    var body: some View {
        let status = String(localized: "Available", bundle: SkillsManagerLocalizationResources.bundle)
        let source = String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
        SkillListRow(data: SkillListRowData(
            id: skill.id,
            title: skill.displayName,
            detail: skill.summary ?? "",
            statusIcon: "arrow.down.circle",
            statusTint: .accentColor,
            sources: [SkillListSourceLabel(
                text: "ClawHub",
                systemImage: "sparkles",
                knownSource: .clawHub
            )],
            agentCount: installedTargets.count,
            accessibilityLabel: [
                skill.displayName,
                status,
                source,
                SkillListAgentSummary.text(count: installedTargets.count),
            ].filter { !$0.isEmpty }.joined(separator: ", "),
            accessibilityValue: [
                status,
                source,
                SkillListAgentSummary.text(count: installedTargets.count),
            ].filter { !$0.isEmpty }.joined(separator: ", ")
        ))
        .padding(.trailing, 26)
        .overlay(alignment: .topTrailing) {
            Button {
                onInstall()
            } label: {
                Image(systemName: isInstalled
                    ? "arrow.triangle.2.circlepath.circle"
                    : "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .help(Text(isInstalled ? "Review or update" : "Install", bundle: SkillsManagerLocalizationResources.bundle))
            .accessibilityLabel(Text(
                isInstalled
                    ? "Review or update \(skill.displayName)"
                    : "Install \(skill.displayName)",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        }
    }

    private var isInstalled: Bool { !installedTargets.isEmpty }

}
