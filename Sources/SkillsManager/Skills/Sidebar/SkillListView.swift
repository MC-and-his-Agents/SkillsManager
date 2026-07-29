import SwiftUI

struct SkillListView: View {
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore

    let localSkills: [Skill]
    let remoteLatestSkills: [RemoteSkill]
    let remoteSearchResults: [RemoteSkill]
    let remoteSearchState: RemoteSkillStore.LoadState
    let remoteLatestState: RemoteSkillStore.LoadState
    let remoteQuery: String
    let installedSkillPlatforms: InstalledSkillPlatformIndex
    let onInstallRemoteSkill: (RemoteSkill) -> Void

    @Binding var source: SkillSource
    @Binding var localSelection: Skill.ID?
    @Binding var remoteSelection: RemoteSkill.ID?

    var body: some View {
        List(selection: source == .local ? $localSelection : $remoteSelection) {
            if source == .local {
                SidebarHeaderView(
                    skillCount: localSkills.count,
                    source: $source
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                localSectionContent()
            } else {
                SidebarHeaderView(
                    skillCount: remoteLatestSkills.count,
                    source: $source
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if shouldShowSearchSection {
                    Section("Search Results") {
                        searchSectionContent
                    }
                }

                Section("Latest Drops") {
                    latestSectionContent
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        switch source {
                        case .local:
                            await store.loadSkills()
                        case .discovery, .skillsSh:
                            break
                        case .clawdhub:
                            await remoteStore.loadLatest()
                        }
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private var shouldShowSearchSection: Bool {
        !remoteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var searchSectionContent: some View {
        if remoteSearchState == .loading {
            HStack {
                ProgressView()
                Text("Searching…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if case let .failed(message) = remoteSearchState {
            Text("Search failed: \(message)")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else if remoteSearchResults.isEmpty {
            Text("No results yet.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(remoteSearchResults) { skill in
                RemoteSkillRowView(
                    skill: skill,
                    installedTargets: installedSkillPlatforms.platforms(forSlug: skill.slug),
                    onInstall: { onInstallRemoteSkill(skill) }
                )
            }
        }
    }

    @ViewBuilder
    private var latestSectionContent: some View {
        if remoteLatestState == .loading {
            HStack {
                ProgressView()
                Text("Loading latest…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if case let .failed(message) = remoteLatestState {
            Text("Latest drops unavailable: \(message)")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else if remoteLatestSkills.isEmpty {
            Text("No skills yet.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(remoteLatestSkills) { skill in
                RemoteSkillRowView(
                    skill: skill,
                    installedTargets: installedSkillPlatforms.platforms(forSlug: skill.slug),
                    onInstall: { onInstallRemoteSkill(skill) }
                )
            }
        }
    }

    @ViewBuilder
    private func localSectionContent() -> some View {
        let mine = localSkills.filter(store.isOwnedSkill)
        let clawdhub = localSkills.filter { !store.isOwnedSkill($0) }

        let hasAnySkills = !mine.isEmpty || !clawdhub.isEmpty

        if !hasAnySkills {
            Text("No skills yet.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            // Platform skill sections
            Section("Mine") {
                localRows(for: mine)
            }
            Section("Clawdhub") {
                localRows(for: clawdhub)
            }
        }
    }

    @ViewBuilder
    private func localRows(for skills: [Skill]) -> some View {
        ForEach(skills) { skill in
            SkillRowView(
                skill: skill,
                installedPlatforms: skill.enabledPlatforms
            )
        }
    }
}
