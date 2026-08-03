import SwiftUI

struct SkillListView: View {
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillsShSearchStore.self) private var skillsShStore
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel

    let localSkills: [Skill]
    let discoveryItems: [SkillDiscoveryViewModel.Item]
    let query: String
    let installedSkillPlatforms: InstalledSkillPlatformIndex
    let onInstallRemoteSkill: (RemoteSkill) -> Void
    @Binding var selection: UnifiedSkillSelection?

    var body: some View {
        List(selection: $selection) {
            header
            Section("On This Mac") {
                localContent
            }

            if normalizedQuery.isEmpty {
                Section("ClawHub Latest Drops") {
                    clawHubLatestContent
                }
            } else {
                Section("ClawHub") {
                    clawHubSearchContent
                }
                Section("skills.sh") {
                    skillsShSearchContent
                }
            }

            if !discoveryModel.rootDiagnostics.isEmpty {
                Section("Unavailable Locations") {
                    discoveryDiagnostics
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    if discoveryModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh Skills", systemImage: "arrow.clockwise")
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(discoveryModel.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(
                    discoveryModel.isRefreshing ? "Refreshing Skills" : "Refresh Skills"
                )
            }
        }
    }

    private var normalizedQuery: String {
        normalizedSkillSearchQuery(query)
    }

    private var visibleCount: Int {
        let remoteCount = normalizedQuery.isEmpty
            ? remoteStore.latestSkills.count
            : remoteStore.searchResults.count + skillsShStore.items.count
        return localSkills.count + discoveryItems.count + remoteCount
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Skills")
                .font(.title2.bold())
            Text("\(visibleCount) shown")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var localContent: some View {
        ForEach(localSkills) { skill in
            SkillRowView(skill: skill, installedPlatforms: skill.enabledPlatforms)
                .tag(UnifiedSkillSelection.managed(skill.id))
        }

        ForEach(discoveryItems) { item in
            SkillDiscoveryRow(item: item)
                .tag(UnifiedSkillSelection.discovered(item.id))
        }

        switch discoveryModel.loadState {
        case .blocked(let message):
            statusRow("Discovery unavailable", message: message, icon: "lock.trianglebadge.exclamationmark")
        case .idle, .loading:
            progressRow("Scanning registered folders")
        case .failed(let message):
            statusRow("Discovery failed", message: message, icon: "exclamationmark.triangle")
        case .loaded:
            if localSkills.isEmpty && discoveryItems.isEmpty {
                statusRow(
                    normalizedQuery.isEmpty ? "No Skills found" : "No local matches",
                    message: normalizedQuery.isEmpty
                        ? "Refresh discovery or import a Skill to get started."
                        : "No local Skills match this search.",
                    icon: "sparkles"
                )
            } else if discoveryModel.isRefreshing {
                progressRow("Refreshing local Skills")
            }
        }
    }

    @ViewBuilder
    private var clawHubLatestContent: some View {
        switch remoteStore.latestState {
        case .idle, .loading:
            progressRow("Loading latest ClawHub Skills")
        case .failed:
            clawHubFailure("Retry ClawHub latest Skills") {
                await remoteStore.loadLatest()
            }
        case .loaded:
            if remoteStore.latestSkills.isEmpty {
                emptyRow("No latest Skills available.")
            } else {
                clawHubRows(remoteStore.latestSkills)
                clawHubPagination(
                    remoteStore.latestPaginationState,
                    loadingLabel: "Loading more latest Skills",
                    retryLabel: "Retry ClawHub latest page"
                ) {
                    await remoteStore.loadMoreLatest()
                }
            }
        }
    }

    @ViewBuilder
    private var clawHubSearchContent: some View {
        switch remoteStore.searchState {
        case .idle, .loading:
            progressRow("Searching ClawHub")
        case .failed:
            clawHubFailure("Retry ClawHub search") {
                await remoteStore.search(query: normalizedQuery)
            }
        case .loaded:
            if remoteStore.searchResults.isEmpty {
                emptyRow("No ClawHub results.")
            } else {
                clawHubRows(remoteStore.searchResults)
                clawHubPagination(
                    remoteStore.searchPaginationState,
                    loadingLabel: "Loading more ClawHub results",
                    retryLabel: "Retry ClawHub search page"
                ) {
                    await remoteStore.loadMoreSearch()
                }
            }
        }
    }

    @ViewBuilder
    private func clawHubRows(_ skills: [RemoteSkill]) -> some View {
        ForEach(skills) { skill in
            RemoteSkillRowView(
                skill: skill,
                installedTargets: installedSkillPlatforms.platforms(forSlug: skill.slug),
                onInstall: { onInstallRemoteSkill(skill) }
            )
            .tag(UnifiedSkillSelection.clawHub(skill.id))
        }
    }

    @ViewBuilder
    private func clawHubPagination(
        _ state: RemoteSkillStore.PaginationState,
        loadingLabel: String,
        retryLabel: String,
        action: @escaping () async -> Void
    ) -> some View {
        switch state {
        case .idle, .finished:
            EmptyView()
        case .loading:
            progressRow(loadingLabel)
        case .canLoadMore:
            Button("Load More") { Task { await action() } }
                .frame(maxWidth: .infinity)
                .accessibilityHint("Loads more ClawHub results")
        case .failed:
            clawHubFailure(retryLabel, action: action)
        }
    }

    @ViewBuilder
    private var skillsShSearchContent: some View {
        switch skillsShStore.searchState {
        case .idle, .loading:
            progressRow("Searching skills.sh")
        case .failed(let problem):
            skillsShFailure(problem, title: "Retry") {
                await skillsShStore.search(query: normalizedQuery)
            }
        case .loaded:
            if skillsShStore.items.isEmpty {
                emptyRow("No skills.sh results.")
            } else {
                ForEach(skillsShStore.items, id: \.resultID) { item in
                    SkillsShSearchRow(item: item)
                        .tag(UnifiedSkillSelection.skillsSh(item.resultID))
                }
                skillsShPagination
            }
        }
    }

    @ViewBuilder
    private var skillsShPagination: some View {
        switch skillsShStore.paginationState {
        case .idle:
            EmptyView()
        case .loading:
            progressRow("Loading more skills.sh results")
        case .canLoadMore:
            Button("Load More") { Task { await skillsShStore.loadNextPage() } }
                .frame(maxWidth: .infinity)
                .accessibilityHint("Loads more skills.sh results")
        case .finished:
            emptyRow("No more unique results.")
        case .failed(let problem):
            skillsShFailure(problem, title: "Retry Page") {
                await skillsShStore.loadNextPage()
            }
        }
    }

    private var discoveryDiagnostics: some View {
        ForEach(discoveryModel.rootDiagnostics, id: \.self) { diagnostic in
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnostic.root.url.path).lineLimit(1)
                    Text(diagnostic.reason.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Unavailable scan location")
            .accessibilityValue(diagnostic.accessibilitySummary)
        }
    }

    private func progressRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(label).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func statusRow(_ title: String, message: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func clawHubFailure(
        _ retryLabel: String,
        action: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ClawdhubAvailabilityPresentation.title, systemImage: "exclamationmark.triangle")
            Text(ClawdhubAvailabilityPresentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { Task { await action() } }
                .accessibilityLabel(retryLabel)
        }
        .padding(.vertical, 8)
    }

    private func skillsShFailure(
        _ problem: SkillsShSearchStore.Problem,
        title: String,
        action: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(problem == .invalidRequest ? "Invalid search" : "skills.sh unavailable")
                .font(.headline)
            Text(problem.message).foregroundStyle(.secondary)
            Button(title) { Task { await action() } }
        }
        .padding(.vertical, 8)
    }

    private func refresh() async {
        async let local: Void = store.loadSkills()
        async let discovery: Void = discoveryModel.refresh()
        async let latest: Void = remoteStore.loadLatest()
        _ = await (local, discovery, latest)
    }
}
