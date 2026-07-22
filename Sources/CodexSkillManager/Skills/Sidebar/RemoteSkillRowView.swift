import SwiftUI

struct RemoteSkillRowView: View {
    let skill: RemoteSkill
    let installedTargets: Set<SkillPlatform>
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.displayName)
                .font(.headline)
                .foregroundStyle(.primary)

            if let summary = skill.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                if let version = skill.latestVersion {
                    TagView(text: "v\(version)")
                }

                if let statsText = statsText {
                    TagView(text: statsText)
                }

                ForEach(SkillPlatform.allCases) { platform in
                    if installedTargets.contains(platform) {
                        TagView(text: platform.rawValue, tint: platform.badgeTint)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            Button {
                onInstall()
            } label: {
                Image(systemName: isInstalledEverywhere ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(isInstalledEverywhere ? .green : .primary)
            }
            .buttonStyle(.borderless)
            .disabled(isInstalledEverywhere)
            .help(isInstalledEverywhere ? "Installed" : "Install")
        }
    }

    private var statsText: String? {
        let downloads = skill.downloads ?? 0
        let stars = skill.stars ?? 0
        guard downloads > 0 || stars > 0 else { return nil }
        return "⬇ \(downloads)  ⭐ \(stars)"
    }

    private var isInstalledEverywhere: Bool {
        installedTargets == Set(SkillPlatform.allCases)
    }
}
