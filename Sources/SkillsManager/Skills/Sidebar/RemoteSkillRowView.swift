import SwiftUI

struct RemoteSkillRowView: View {
    let skill: RemoteSkill
    let installedTargets: Set<SkillPlatform>
    let onInstall: () -> Void

    var body: some View {
        let status = String(localized: "Available", bundle: SkillsManagerLocalizationResources.bundle)
        let source = String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
        let status = String(localized: "Available", bundle: SkillsManagerLocalizationResources.bundle)
        let source = String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
        let agentSummary = isInstalled
            ? SkillListAgentSummary.text(count: installedTargets.count)
            : nil
        HStack(spacing: 8) {
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
                agentCount: isInstalled ? installedTargets.count : nil,
                accessibilityLabel: [
                    skill.displayName,
                    status,
                    source,
                    agentSummary,
                ].compactMap { $0 }.joined(separator: ", "),
                accessibilityValue: [
                    status,
                    source,
                    agentSummary,
                ].compactMap { $0 }.joined(separator: ", ")
            ))

            installButton
        }
    }

    /// 行尾固定尺寸安装入口：28×28pt 命中区 + 圆形底色，替代原先
    /// overlay 悬浮的裸图标（热区仅 SF Symbol 原始尺寸，且需 padding hack 避让）。
    private var installButton: some View {
        Button {
            onInstall()
        } label: {
            Image(systemName: isInstalled
                ? "arrow.triangle.2.circlepath.circle"
                : "arrow.down.circle")
                .foregroundStyle(isInstalled ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(Text(isInstalled ? "Review or update" : "Install", bundle: SkillsManagerLocalizationResources.bundle))
        .accessibilityLabel(Text(
            isInstalled
                ? "Review or update \(skill.displayName)"
                : "Install \(skill.displayName)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        .accessibilityIdentifier("skills.remote.row-install")
    }

    private var isInstalled: Bool { !installedTargets.isEmpty }

(fix(ui): 远程行安装按钮改为行内固定尺寸控件)
            ))

            installButton
        }
    }

    /// 行尾固定尺寸安装入口：28×28pt 命中区 + 圆形底色，替代原先
    /// overlay 悬浮的裸图标（热区仅 SF Symbol 原始尺寸，且需 padding hack 避让）。
    private var installButton: some View {
        Button {
            onInstall()
        } label: {
            Image(systemName: isInstalled
                ? "arrow.triangle.2.circlepath.circle"
                : "arrow.down.circle")
                .foregroundStyle(isInstalled ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(Text(isInstalled ? "Review or update" : "Install", bundle: SkillsManagerLocalizationResources.bundle))
        .accessibilityLabel(Text(
            isInstalled
                ? "Review or update \(skill.displayName)"
                : "Install \(skill.displayName)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        .accessibilityIdentifier("skills.remote.row-install")
    }

    private var isInstalled: Bool { !installedTargets.isEmpty }

}
