import MarkdownUI
import SwiftUI

struct RemoteSkillDetailView: View {
    @Environment(RemoteSkillStore.self) private var store

    let onInstall: (RemoteSkill) -> Void

    var body: some View {
        if let skill = store.selectedSkill {
            VStack(spacing: 0) {
                SkillResultCenterBanner(subject: .clawHub(skill.id))
                    .padding([.top, .horizontal])
                Group {
                    switch store.detailState {
                    case .idle, .loading:
                        loadingView(for: skill)
                    case .failed:
                        errorView(for: skill)
                    case .loaded, .cachedRefreshing, .cachedUnavailable:
                        markdownView(for: skill)
                    }
                }
            }
            .navigationTitle(skill.displayName)
            .navigationSubtitle(String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle))
        } else {
            ContentUnavailableView(
                String(localized: "Select a skill", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "sparkles",
                description: Text("Pick a skill from ClawHub.", bundle: SkillsManagerLocalizationResources.bundle)
            )
        }
    }

    private func loadingView(for skill: RemoteSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView(for: skill)
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading SKILL.md…", bundle: SkillsManagerLocalizationResources.bundle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private func errorView(for skill: RemoteSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView(for: skill)
            Label {
                Text("ClawHub unavailable", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            Text("Try again without affecting your local Skills.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)
            retryButton
            Spacer()
        }
        .padding()
    }

    private func markdownView(for skill: RemoteSkill) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerView(for: skill)
                if store.detailState == .cachedUnavailable {
                    HStack {
                        Label {
                            Text("ClawHub unavailable — cached content may be out of date.", bundle: SkillsManagerLocalizationResources.bundle)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        Spacer()
                        retryButton
                    }
                    .foregroundStyle(.orange)
                }
                Markdown(store.detailMarkdown)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var retryButton: some View {
        Button {
            Task { await store.loadSelectedSkill() }
        } label: {
            Text("Retry", bundle: SkillsManagerLocalizationResources.bundle)
        }
        .disabled(store.detailState == .loading || store.detailState == .cachedRefreshing)
        .accessibilityLabel(Text("Retry loading this Skill from ClawHub", bundle: SkillsManagerLocalizationResources.bundle))
    }

    private func headerView(for skill: RemoteSkill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: skill.displayName)
                .font(.largeTitle.bold())
            if let summary = skill.summary {
                Text(verbatim: summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let owner = ownerDisplayName {
                    TagView(localized: LocalizedStringResource(
            "By \(owner)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                }
                if let version = skill.latestVersion {
                    TagView(localized: LocalizedStringResource(
                        "Version \(version)",
                        bundle: SkillsManagerLocalizationResources.bundle
                    ))
                }
                remoteStatsView(for: skill)
            }
            HStack(spacing: 12) {
                Button {
                    onInstall(skill)
                } label: {
                    Label {
                        Text("Install", bundle: SkillsManagerLocalizationResources.bundle)
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("skills.remote.install")
                .accessibilityLabel(Text("Install this ClawHub Skill", bundle: SkillsManagerLocalizationResources.bundle))
                .accessibilityHint(Text(
                    "Opens the installation review. Nothing is written until you confirm.",
                    bundle: SkillsManagerLocalizationResources.bundle
                ))
                Button {
                    openClawdhubURL(for: skill)
                } label: {
                    Label {
                        Text("Open on ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
                    } icon: {
                        Image(systemName: "globe")
                    }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openClawdhubURL(for skill: RemoteSkill) {
        guard let url = URL(string: "https://clawdhub.com/skills/\(skill.slug)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 下载/星标统计：SF Symbols 图标 + 本地化数字，替代此前的
    /// "⬇ N  ⭐ N" emoji 文本 tag。
    @ViewBuilder
    private func remoteStatsView(for skill: RemoteSkill) -> some View {
        let downloads = skill.downloads ?? 0
        let stars = skill.stars ?? 0
        if downloads > 0 || stars > 0 {
            HStack(spacing: 12) {
                if downloads > 0 {
                    Label {
                        Text(String(
                            localized: LocalizedStringResource(
                    "\(downloads) downloads",
                    bundle: SkillsManagerLocalizationResources.bundle
                )))
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                if stars > 0 {
                    Label {
                        Text(String(
                            localized: LocalizedStringResource(
                    "\(stars) stars",
                    bundle: SkillsManagerLocalizationResources.bundle
                )))
                    } icon: {
                        Image(systemName: "star")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var ownerDisplayName: String? {
        guard let owner = store.detailOwner else { return nil }
        if let displayName = owner.displayName, !displayName.isEmpty {
            return displayName
        }
        if let handle = owner.handle, !handle.isEmpty {
            return "@\(handle)"
        }
        return nil
    }

}
