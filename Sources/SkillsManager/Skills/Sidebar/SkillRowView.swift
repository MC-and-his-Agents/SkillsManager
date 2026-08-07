import SwiftUI

struct SkillRowView: View {
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

    var body: some View {
        SkillListRow(data: SkillListRowData(
            id: skill.id,
            title: skill.displayName,
            detail: skill.description,
            statusIcon: statusIcon,
            statusTint: statusTint,
            sources: skill.listOrigin.labels,
            agentCount: skill.enabledPlatforms.count,
            accessibilityLabel: [
                skill.displayName,
                statusText,
                skill.listOrigin.labels.map(\.text).joined(separator: ", "),
                SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
            ].filter { !$0.isEmpty }.joined(separator: ", "),
            accessibilityValue: [
                statusText,
                skill.listOrigin.labels.map(\.text).joined(separator: ", "),
                SkillListAgentSummary.text(count: skill.enabledPlatforms.count),
            ].filter { !$0.isEmpty }.joined(separator: ", ")
        ))
    }
}
