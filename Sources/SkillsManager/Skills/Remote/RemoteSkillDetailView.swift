import MarkdownUI
import SwiftUI

struct RemoteSkillDetailView: View {
    @Environment(RemoteSkillStore.self) private var store

    let onInstall: (RemoteSkill) -> Void

    var body: some View {
        if let skill = store.selectedSkill {
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
            .navigationTitle(skill.displayName)
            .navigationSubtitle(String(localized: "ClawHub", bundle: .module))
        } else {
            ContentUnavailableView(
                String(localized: "Select a skill", bundle: .module),
                systemImage: "sparkles",
                description: Text("Pick a skill from ClawHub.", bundle: .module)
            )
        }
    }

    private func loadingView(for skill: RemoteSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView(for: skill)
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading SKILL.md…", bundle: .module)
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
                Text("ClawHub unavailable", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            Text("Try again without affecting your local Skills.", bundle: .module)
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
                            Text("ClawHub unavailable — cached content may be out of date.", bundle: .module)
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
            Text("Retry", bundle: .module)
        }
        .disabled(store.detailState == .loading || store.detailState == .cachedRefreshing)
        .accessibilityLabel(Text("Retry loading this Skill from ClawHub", bundle: .module))
    }

    private func headerView(for skill: RemoteSkill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.displayName)
                .font(.largeTitle.bold())
            if let summary = skill.summary {
                Text(summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let owner = ownerDisplayName {
                    TagView(localized: LocalizedStringResource(
                        "By %@",
                        defaultValue: "By \(owner)",
                        bundle: .module
                    ))
                }
                if let version = skill.latestVersion {
                    TagView(text: "v\(version)")
                }
                if let statsText = statsText(for: skill) {
                    TagView(text: statsText)
                }
            }
            HStack(spacing: 12) {
                Button {
                    onInstall(skill)
                } label: {
                    Label {
                        Text("Install", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("skills.remote.install")
                .accessibilityLabel(Text("Install this ClawHub Skill", bundle: .module))
                .accessibilityHint(Text(
                    "Opens the installation review. Nothing is written until you confirm.",
                    bundle: .module
                ))
                Button {
                    openClawdhubURL(for: skill)
                } label: {
                    Label {
                        Text("Open on ClawHub", bundle: .module)
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

    private func statsText(for skill: RemoteSkill) -> String? {
        let downloads = skill.downloads ?? 0
        let stars = skill.stars ?? 0
        guard downloads > 0 || stars > 0 else { return nil }
        return "⬇ \(downloads)  ⭐ \(stars)"
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
