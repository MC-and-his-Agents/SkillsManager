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
                Section {
                    localContent
                } header: {
                    Text("On This Mac", bundle: .module)
                }
            }

            if normalizedQuery.isEmpty {
                if filters.includesRemote(.clawHub) {
                    Section {
                        clawHubLatestContent
                    } header: {
                        Text("ClawHub Latest Drops", bundle: .module)
                    }
                }
            } else {
                if filters.includesRemote(.clawHub) {
                    Section {
                        clawHubSearchContent
                    } header: {
                        Text("ClawHub", bundle: .module)
                    }
                }
                if filters.includesRemote(.skillsSh) {
                    Section {
                        skillsShSearchContent
                    } header: {
                        Text("skills.sh", bundle: .module)
                    }
                }
            }

            if filters.includesRemote(.repository) {
                Section {
                    repositoryContent
                } header: {
                    Text("Repositories", bundle: .module)
                }
            }

            if !discoveryModel.rootDiagnostics.isEmpty {
                Section {
                    discoveryDiagnostics
                } header: {
                    Text("Unavailable Locations", bundle: .module)
                }
            }

            if !hasIncludedSkillChannel {
                Section {
                    emptyRow(String(localized: "No Skills match the current filters.", bundle: .module))
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
                        Label {
                            Text("Refresh Skills", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(discoveryModel.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(Text(
                    discoveryModel.isRefreshing ? "Refreshing Skills" : "Refresh Skills",
                    bundle: .module
                ))
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
                Text("Skills", bundle: .module)
                    .font(.title2.bold())
                Text(String(
                    localized: LocalizedStringResource( "%lld shown",
                    defaultValue: "\(visibleCount) shown",
                    bundle: .module
                )))
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
                statusRow(
                    String(localized: "Discovery unavailable", bundle: .module),
                    message: message,
                    icon: "lock.trianglebadge.exclamationmark"
                )
            case .idle, .loading:
                progressRow(String(localized: "Scanning registered folders", bundle: .module))
            case .failed(let message):
                statusRow(
                    String(localized: "Discovery failed", bundle: .module),
                    message: message,
                    icon: "exclamationmark.triangle"
                )
            case .loaded:
                if localSkills.isEmpty && discoveryItems.isEmpty {
                    localEmptyState
                } else if discoveryModel.isRefreshing {
                    progressRow(String(localized: "Refreshing local Skills", bundle: .module))
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
                progressRow(String(localized: "Refreshing GitHub repositories", bundle: .module))
            } else if customRepositoryModel.repositories.isEmpty {
                emptyRow(String(localized: "No GitHub repositories registered.", bundle: .module))
            } else if let failure = customRepositoryModel.repositories.lazy.compactMap({ record in
                if case .failed(let problem) = customRepositoryModel.state(
                    for: record.repositoryID
                ) { problem } else { nil }
            }).first {
                statusRow(
                    String(localized: "Repository unavailable", bundle: .module),
                    message: failure.message,
                    icon: "exclamationmark.triangle"
                )
            } else {
                emptyRow(String(localized: "No Skills found in the registered repositories.", bundle: .module))
            }
        }
    }

    private var localEmptyState: some View {
        let constrained = !normalizedQuery.isEmpty || filters.isActive
        return SkillListEmptyRow(
            title: constrained
                ? String(localized: "No local matches", bundle: .module)
                : String(localized: "No Skills found", bundle: .module),
            message: constrained
                ? String(localized: "No local Skills match the current search and filters.", bundle: .module)
                : String(localized: "Refresh discovery or import a Skill to get started.", bundle: .module),
            icon: "sparkles"
        )
    }

    @ViewBuilder
    private var clawHubLatestContent: some View {
        switch remoteStore.latestState {
        case .idle, .loading:
            progressRow(String(localized: "Loading latest ClawHub Skills", bundle: .module))
        case .failed:
            clawHubFailure(String(localized: "Retry ClawHub latest Skills", bundle: .module)) {
                await remoteStore.loadLatest()
            }
        case .loaded:
            if remoteStore.latestSkills.isEmpty {
                emptyRow(String(localized: "No latest Skills available.", bundle: .module))
            } else {
                clawHubRows(remoteStore.latestSkills)
                clawHubPagination(
                    remoteStore.latestPaginationState,
                    loadingLabel: String(localized: "Loading more latest Skills", bundle: .module),
                    retryLabel: String(localized: "Retry ClawHub latest page", bundle: .module)
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
            progressRow(String(localized: "Searching ClawHub", bundle: .module))
        case .failed:
            clawHubFailure(String(localized: "Retry ClawHub search", bundle: .module)) {
                await remoteStore.search(query: normalizedQuery)
            }
        case .loaded:
            if remoteStore.searchResults.isEmpty {
                emptyRow(String(localized: "No ClawHub results.", bundle: .module))
            } else {
                clawHubRows(remoteStore.searchResults)
                clawHubPagination(
                    remoteStore.searchPaginationState,
                    loadingLabel: String(localized: "Loading more ClawHub results", bundle: .module),
                    retryLabel: String(localized: "Retry ClawHub search page", bundle: .module)
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
            Button {
                Task { await action() }
            } label: {
                Text("Load More", bundle: .module)
            }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("clawhub.load-more")
                .accessibilityHint(Text("Loads more ClawHub results", bundle: .module))
        case .failed:
            clawHubFailure(retryLabel, action: action)
        }
    }

    @ViewBuilder
    private var skillsShSearchContent: some View {
        switch skillsShStore.searchState {
        case .idle, .loading:
            progressRow(String(localized: "Searching skills.sh", bundle: .module))
        case .failed(let problem):
            skillsShFailure(problem, title: String(localized: "Retry", bundle: .module)) {
                await skillsShStore.search(query: normalizedQuery)
            }
        case .loaded:
            if skillsShStore.items.isEmpty {
                emptyRow(String(localized: "No skills.sh results.", bundle: .module))
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
            progressRow(String(localized: "Loading more skills.sh results", bundle: .module))
        case .canLoadMore:
            Button {
                Task { await skillsShStore.loadNextPage() }
            } label: {
                Text("Load More", bundle: .module)
            }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("skills-sh.load-more")
                .accessibilityHint(Text("Loads more skills.sh results", bundle: .module))
        case .finished:
            emptyRow(String(localized: "No more unique results.", bundle: .module))
        case .failed(let problem):
            skillsShFailure(problem, title: String(localized: "Retry Page", bundle: .module)) {
                await skillsShStore.loadNextPage()
            }
        }
    }

    private var discoveryDiagnostics: some View {
        ForEach(discoveryModel.rootDiagnostics, id: \.self) { diagnostic in
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnostic.root.url.path).lineLimit(1)
                    Text(verbatim: diagnostic.reason.localizedDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Unavailable scan location", bundle: .module))
            .accessibilityValue(String(
                localized: LocalizedStringResource( "%@, %@, %@",
                defaultValue: "\(diagnostic.root.scope.localizedDisplayName), \(diagnostic.root.url.path), \(diagnostic.reason.localizedDisplayName)",
                bundle: .module
            )))
        }
    }

    private func progressRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(verbatim: label).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func emptyRow(_ text: String) -> some View {
        SkillListEmptyRow(title: text)
    }

    private func statusRow(_ title: String, message: String, icon: String) -> some View {
        SkillListEmptyRow(title: title, message: message, icon: icon)
    }

    private func clawHubFailure(
        _ retryLabel: String,
        action: @escaping () async -> Void
    ) -> some View {
        return SkillListEmptyRow(
            title: ClawdhubAvailabilityPresentation.title,
            message: ClawdhubAvailabilityPresentation.detail,
            icon: "exclamationmark.triangle",
            actionTitle: "Retry",
            actionAccessibilityLabel: retryLabel
        ) {
            Task { await action() }
        }
    }

    private func skillsShFailure(
        _ problem: SkillsShSearchStore.Problem,
        title: String,
        action: @escaping () async -> Void
    ) -> some View {
        let localizedTitle = switch problem {
        case .invalidRequest:
            String(localized: "Invalid search", bundle: .module)
        default:
            String(localized: "skills.sh unavailable", bundle: .module)
        }
        return SkillListEmptyRow(
            title: localizedTitle,
            message: problem.message,
            icon: "exclamationmark.triangle",
            actionTitle: title,
            actionAccessibilityLabel: title
        ) {
            Task { await action() }
        }
    }

    private func refresh() async {
        async let local: Void = store.loadSkills()
        async let discovery: Void = discoveryModel.refresh()
        async let latest: Void = remoteStore.loadLatest()
        async let repositories: Void = customRepositoryModel.refreshAll()
        _ = await (local, discovery, latest, repositories)
    }
}
