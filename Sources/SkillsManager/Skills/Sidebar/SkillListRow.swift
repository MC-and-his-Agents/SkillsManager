import SwiftUI

/// 统一列表行：第 1 行名字 + 状态图标、第 2 行单行描述、
/// 行尾来源图标（tooltip）+ Agent 数 + 更新/修复徽章（#185）。
///
/// 五种行（managed/discovery/ClawHub/skills.sh/repository）统一使用本组件；
/// 身份摘要与多余 tag 移入详情页，行内只保留浏览所需信息。
struct SkillListRow: View {
    let data: SkillListRowData
    var badge: SkillRowBadge? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: data.statusIcon)
                .foregroundStyle(data.statusTint)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(data.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let badge {
                badgeView(badge)
            }

            HStack(spacing: 8) {
                ForEach(data.sources) { label in
                    Image(systemName: label.systemImage)
                        .help(localized(label.text))
                        .accessibilityLabel(Text("Source: \(localized(label.text))", bundle: .module))
                }
                if let agentCount = data.agentCount {
                    Text(SkillListAgentSummary.text(count: agentCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            SkillListAgentSummary.text(count: agentCount)
                        )
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(data.accessibilityLabel)
        .accessibilityValue(data.accessibilityValue)
    }

    @ViewBuilder
    private func badgeView(_ badge: SkillRowBadge) -> some View {
        switch badge {
        case .updateAvailable(let version):
            Label {
                Text("↻ v\(version)", bundle: .module)
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Update available, version \(version)", bundle: .module))
        case .needsAttention:
            Label {
                Text("Needs Repair", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(.yellow)
                .accessibilityLabel(Text("Needs Repair", bundle: .module))
        }
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}

/// 行内徽章（#185）：更新可用（绿）与需修复（黄）。
enum SkillRowBadge: Equatable {
    case updateAvailable(version: String)
    case needsAttention
}

/// 统一行的数据载体；五种来源在此适配为同一呈现。
struct SkillListRowData: Identifiable {
    let id: String
    let title: String
    let detail: String
    let statusIcon: String
    let statusTint: Color
    let sources: [SkillListSourceLabel]
    let agentCount: Int?
    let accessibilityLabel: String
    let accessibilityValue: String
}
