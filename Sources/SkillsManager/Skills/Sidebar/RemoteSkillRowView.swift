import SwiftUI

struct RemoteSkillRowView: View {
    let skill: RemoteSkill
    let installedTargets: Set<SkillPlatform>
    let onInstall: () -> Void

    var body: some View {
        let status = localized("Available")
        let source = localized("ClawHub")
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
            .help(Text(isInstalled ? "Review or update" : "Install", bundle: .module))
            .accessibilityLabel(Text(
                isInstalled
                    ? "Review or update \(skill.displayName)"
                    : "Install \(skill.displayName)",
                bundle: .module
            ))
        }
    }

    private var isInstalled: Bool { !installedTargets.isEmpty }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
