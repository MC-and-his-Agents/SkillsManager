import SwiftUI

struct SkillListView: View {
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillsShSearchStore.self) private var skillsShStore
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(CustomRepositoryViewModel.self) private var customRepositoryModel

    let localSkills: [Skill]
    let discoveryItems: [SkillDiscoveryViewModel.Item]
    let repositoryCandidates: [CustomRepositoryCandidate]
    let query: String
    @Binding var filters: SkillListFilters
    let installedSkillPlatforms: InstalledSkillPlatformIndex
    let onInstallRemoteSkill: (RemoteSkill) -> Void
    @Binding var selection: UnifiedSkillSelection?

    var body: some View {
        List(selection: $selection) {
            header
            SkillFilterBar(filters: $filters)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 10, trailing: 4))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if filters.status != .available {
                Section("On This Mac") {
                    localContent
                }
            }

            if normalizedQuery.isEmpty {
                if filters.includesRemote(.clawHub) {
                    Section("ClawHub Latest Drops") {
                        clawHubLatestContent
                    }
                }
            } else {
                if filters.includesRemote(.clawHub) {
                    Section("ClawHub") {
                        clawHubSearchContent
                    }
                }
                if filters.includesRemote(.skillsSh) {
                    Section("skills.sh") {
                        skillsShSearchContent
                    }
                }
            }

            if filters.includesRemote(.repository) {
                Section("Repositories") {
                    repositoryContent
                }
            }

            if !discoveryModel.rootDiagnostics.isEmpty {
                Section("Unavailable Locations") {
                    discoveryDiagnostics
                }
            }

            if !hasIncludedSkillChannel {
                Section {
                    emptyRow("No Skills match the current filters.")
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
                .accessibilityIdentifier("skills.refresh")
            }
        }
    }

    private var normalizedQuery: String {
        normalizedSkillSearchQuery(query)
    }

    private var hasIncludedSkillChannel: Bool {
        if filters.status != .available { return true }
        if filters.includesRemote(.repository) { return true }
        if normalizedQuery.isEmpty { return filters.includesRemote(.clawHub) }
        return filters.includesRemote(.clawHub) || filters.includesRemote(.skillsSh)
    }

    private var visibleCount: Int {
        let remoteCount: Int
        if normalizedQuery.isEmpty {
            remoteCount = filters.includesRemote(.clawHub)
                && remoteStore.latestState == .loaded
                ? remoteStore.latestSkills.count : 0
        } else {
            remoteCount = (filters.includesRemote(.clawHub)
                && remoteStore.searchState == .loaded ? remoteStore.searchResults.count : 0)
                + (filters.includesRemote(.skillsSh)
                    && skillsShStore.searchState == .loaded ? skillsShStore.items.count : 0)
        }
        return localSkills.count + discoveryItems.count + repositoryCandidates.count + remoteCount
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skills")
                    .font(.title2.bold())
                Text("\(visibleCount) shown")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var localContent: some View {
        ForEach(localSkills) { skill in
            SkillRowView(skill: skill)
                .tag(UnifiedSkillSelection.managed(skill.id))
        }

        ForEach(discoveryItems) { item in
            SkillDiscoveryRow(item: item)
                .tag(UnifiedSkillSelection.discovered(item.id))
        }

        if includesDiscoveryChannel {
            switch discoveryModel.loadState {
            case .blocked(let message):
                statusRow("Discovery unavailable", message: message, icon: "lock.trianglebadge.exclamationmark")
            case .idle, .loading:
                progressRow("Scanning registered folders")
            case .failed(let message):
                statusRow("Discovery failed", message: message, icon: "exclamationmark.triangle")
            case .loaded:
                if localSkills.isEmpty && discoveryItems.isEmpty {
                    localEmptyState
                } else if discoveryModel.isRefreshing {
                    progressRow("Refreshing local Skills")
                }
            }
        } else if localSkills.isEmpty {
            localEmptyState
        }
    }

    private var includesDiscoveryChannel: Bool {
        filters.status.includesDiscoveryStatus(.unmanaged) && filters.agent == .all
    }

    @ViewBuilder
    private var repositoryContent: some View {
        ForEach(repositoryCandidates) { candidate in
            CustomRepositoryCandidateRow(candidate: candidate)
                .tag(UnifiedSkillSelection.repository(candidate.id))
        }
        if repositoryCandidates.isEmpty {
            if customRepositoryModel.isRefreshing {
                progressRow("Refreshing GitHub repositories")
            } else if customRepositoryModel.repositories.isEmpty {
                emptyRow("No GitHub repositories registered.")
            } else if let failure = customRepositoryModel.repositories.lazy.compactMap({ record in
                if case .failed(let problem) = customRepositoryModel.state(
                    for: record.repositoryID
                ) { problem } else { nil }
            }).first {
                statusRow(
                    "Repository unavailable",
                    message: failure.message,
                    icon: "exclamationmark.triangle"
                )
            } else {
                emptyRow("No Skills found in the registered repositories.")
            }
        }
    }

    private var localEmptyState: some View {
        let constrained = !normalizedQuery.isEmpty || filters.isActive
        return statusRow(
            constrained ? "No local matches" : "No Skills found",
            message: constrained
                ? "No local Skills match the current search and filters."
                : "Refresh discovery or import a Skill to get started.",
            icon: "sparkles"
        )
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
                .accessibilityIdentifier("clawhub.load-more")
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
                .accessibilityIdentifier("skills-sh.load-more")
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
            .accessibilityElement(children: .combine)
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
        async let repositories: Void = customRepositoryModel.refreshAll()
        _ = await (local, discovery, latest, repositories)
    }
}
