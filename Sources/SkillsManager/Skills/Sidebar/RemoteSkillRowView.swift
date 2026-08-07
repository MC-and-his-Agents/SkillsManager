import SwiftUI

struct RemoteSkillRowView: View {
    let skill: RemoteSkill
    let installedTargets: Set<SkillPlatform>
    let onInstall: () -> Void

    var body: some View {
        SkillListRow(data: SkillListRowData(
            id: skill.id,
            title: skill.displayName,
            detail: skill.summary ?? "",
            statusIcon: "arrow.down.circle",
            statusTint: .accentColor,
            sources: [SkillListSourceLabel(text: "ClawHub", systemImage: "sparkles")],
            agentCount: installedTargets.count,
            accessibilityLabel: [
                skill.displayName,
                "Available",
                "ClawHub",
                SkillListAgentSummary.text(count: installedTargets.count),
            ].filter { !$0.isEmpty }.joined(separator: ", "),
            accessibilityValue: [
                "Available",
                "ClawHub",
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
            .help(isInstalled ? "Review or update" : "Install")
            .accessibilityLabel(
                isInstalled
                    ? "Review or update \(skill.displayName)"
                    : "Install \(skill.displayName)"
            )
        }
    }

    private var isInstalled: Bool { !installedTargets.isEmpty }
}
