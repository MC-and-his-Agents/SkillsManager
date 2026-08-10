import SwiftUI

struct SkillSplitView: View {
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillsShSearchStore.self) private var skillsShStore
    @Environment(CustomRepositoryViewModel.self) private var customRepositoryModel
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(SkillDiscoveryBatchViewModel.self) private var discoveryBatchModel
    @Environment(SkillBatchUpdateViewModel.self) private var batchUpdateModel
    @Environment(SkillLifecycleViewModel.self) private var lifecycleModel
    @Environment(SkillConsistencyViewModel.self) private var consistencyModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime
    @Environment(SkillUpdateBadgeStore.self) private var updateBadgeStore

    @State private var searchText = ""
    @State private var filters = SkillListFilters()
    @State private var selection: UnifiedSkillSelection?
    @State private var searchTask: Task<Void, Never>?
    @State private var showingImport = false
    @State private var showingAddPath = false
    @State private var showingBackups = false
    @State private var showingConsistency = false
    @State private var showingDiscoveryBatch = false
    @State private var showingRepositories = false
    @State private var downloadErrorMessage: String?
    @State private var isDownloadingRemote = false
    @State private var didDownloadRemote = false
    @State private var installSkill: RemoteSkill?

    private var query: String {
        normalizedSkillSearchQuery(searchText)
    }

    private var filteredSkills: [Skill] {
        store.skills.filter { skill in
            filters.includesManaged(skill) && (
                query.isEmpty
                    || skill.displayName.localizedCaseInsensitiveContains(query)
                    || skill.description.localizedCaseInsensitiveContains(query)
            )
        }
    }

    private var filteredDiscoveryItems: [SkillDiscoveryViewModel.Item] {
        let canonical = visibleDiscoveryItems(
            discoveryModel.items,
            managedSkillIDs: Set(store.skills.map(\.managedSkillID))
        )
        return canonical.filter { item in
            let observation = item.observation
            return filters.includesDiscovery(observation) && (
                query.isEmpty
                    || observation.relativeLocator.localizedCaseInsensitiveContains(query)
                    || observation.scopeSummary.localizedCaseInsensitiveContains(query)
                    || observation.displayURLs.contains {
                        $0.path.localizedCaseInsensitiveContains(query)
                    }
            )
        }
    }

    private var filteredRepositoryCandidates: [CustomRepositoryCandidate] {
        guard filters.includesRemote(.repository) else { return [] }
        return customRepositoryModel.candidates.filter(repositoryCandidateMatches)
    }

    private var visibleSelections: Set<UnifiedSkillSelection> {
        var values = Set(filteredSkills.map { UnifiedSkillSelection.managed($0.id) })
        values.formUnion(filteredDiscoveryItems.map {
            UnifiedSkillSelection.discovered($0.id)
        })
        values.formUnion(filteredRepositoryCandidates.map {
            UnifiedSkillSelection.repository($0.id)
        })
        if case .repository(let id) = selection,
           filters.includesRemote(.repository),
           let candidate = customRepositoryModel.candidate(id: id),
           repositoryCandidateMatches(candidate) {
            values.insert(.repository(id))
        }
        if query.isEmpty {
            if filters.includesRemote(.clawHub) {
                values.formUnion(visibleRemoteSkillSelections(
                    clawHubSkills: remoteStore.latestSkills,
                    clawHubLoaded: remoteStore.latestState == .loaded
                ))
            }
        } else {
            values.formUnion(visibleRemoteSkillSelections(
                clawHubSkills: filters.includesRemote(.clawHub)
                    ? remoteStore.searchResults : [],
                clawHubLoaded: filters.includesRemote(.clawHub)
                    && remoteStore.searchState == .loaded,
                skillsShItems: filters.includesRemote(.skillsSh)
                    ? skillsShStore.items : [],
                skillsShLoaded: filters.includesRemote(.skillsSh)
                    && skillsShStore.searchState == .loaded
            ))
        }
        return values
    }

    private func repositoryCandidateMatches(_ candidate: CustomRepositoryCandidate) -> Bool {
        query.isEmpty
            || candidate.displayName.localizedCaseInsensitiveContains(query)
            || candidate.repository.repositoryURL.value.localizedCaseInsensitiveContains(query)
            || candidate.snapshot.subpath.value.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        NavigationSplitView {
            SkillListView(
                localSkills: filteredSkills,
                discoveryItems: filteredDiscoveryItems,
                repositoryCandidates: filteredRepositoryCandidates,
                query: query,
                filters: $filters,
                installedSkillPlatforms: store.installedSkillPlatformIndex,
                onInstallRemoteSkill: presentRemoteInstallSheet,
                selection: $selection
            )
        } detail: {
            detailView
        }
        .modifier(
            SkillSplitLifecycleModifier(
                selection: $selection,
                searchText: $searchText,
                searchTask: $searchTask
            )
        )
        .toolbar(id: "main-toolbar") {
            toolbarContent()
        }
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: Text("Search Skills", bundle: .module)
        )
        .sheet(isPresented: $showingImport) {
            ImportSkillView().environment(store)
        }
        .sheet(isPresented: $showingAddPath) {
            AddCustomPathView().environment(store)
        }
        .sheet(isPresented: $showingBackups) {
            SkillBackupLibraryView().environment(lifecycleModel)
        }
        .sheet(isPresented: $showingConsistency) {
            consistencySheet
        }
        .sheet(isPresented: $showingDiscoveryBatch) {
            SkillDiscoveryBatchView()
                .environment(discoveryBatchModel)
        }
        .sheet(isPresented: $showingRepositories) {
            CustomRepositorySheet().environment(customRepositoryModel)
        }
        .sheet(item: $installSkill) { skill in
            ManagedClawdhubInstallView(
                skill: skill,
                isInstalling: $isDownloadingRemote,
                didInstall: $didDownloadRemote,
                errorMessage: $downloadErrorMessage
            )
            .environment(store)
            .environment(remoteStore)
        }
        .onChange(of: selection) { _, newValue in
            let visibleValue = reconciledSkillSelection(
                newValue,
                visibleSelections: visibleSelections
            )
            guard visibleValue == newValue else {
                selection = visibleValue
                return
            }
            applySelection(visibleValue)
        }
        .onChange(of: visibleSelections) { _, visible in
            selection = reconciledSkillSelection(selection, visibleSelections: visible)
        }
        .onChange(of: didDownloadRemote) { _, installed in
            guard installed else { return }
            didDownloadRemote = false
        }
        .onChange(of: batchUpdateModel.state) { _, newValue in
            guard newValue == .completed else { return }
            Task {
                await store.loadSkills()
                await discoveryModel.refresh()
            }
        }
        .onChange(of: store.skills) { _, _ in
            updateBadgeStore.invalidateAll()
            for skill in filteredSkills {
                Task { await updateBadgeStore.checkIfNeeded(for: skill) }
            }
        }
        .onChange(of: filteredSkills) { _, skills in
            for skill in skills {
                Task { await updateBadgeStore.checkIfNeeded(for: skill) }
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .managed:
            SkillDetailView()
        case .discovered:
            SkillDiscoveryDetailView()
        case .repository(let id):
            if let candidate = customRepositoryModel.candidate(id: id) {
                CustomRepositoryCandidateDetailView(candidate: candidate)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Skill unavailable", bundle: .module)
                    } icon: {
                        Image(systemName: "shippingbox")
                    }
                }
            }
        case .clawHub:
            RemoteSkillDetailView(
                onInstall: { presentRemoteInstallSheet(for: $0) }
            )
        case .skillsSh:
            SkillsShSearchDetailView()
        case nil:
            ContentUnavailableView {
                Label {
                    Text("Select a skill", bundle: .module)
                } icon: {
                    Image(systemName: "sparkles")
                }
            } description: {
                Text("Pick a skill from the list.", bundle: .module)
            }
        }
    }

    private var consistencySheet: some View {
        SkillConsistencyAssistantView {
            showingConsistency = false
            Task { @MainActor in
                await Task.yield()
                showingBackups = true
                await lifecycleModel.refreshBackupsOnly()
            }
        }
        .environment(consistencyModel)
    }

    @ToolbarContentBuilder
    private func toolbarContent() -> some CustomizableToolbarContent {
        if canBatchImport {
            ToolbarItem(id: "batch-discovery") {
                Button {
                    presentBatchImport()
                } label: {
                    Label {
                        Text("Batch Import", bundle: .module)
                    } icon: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
                .help(Text("Batch Import discovered Skills", bundle: .module))
                .accessibilityLabel(Text("Batch Import discovered Skills", bundle: .module))
                .accessibilityValue(Text("\(batchCandidateCount) candidates available", bundle: .module))
                .accessibilityIdentifier("skills.batch-import")
            }
        }

        if isLocalSelection || selection == nil {
            ToolbarItem(id: "consistency") {
                Button {
                    showingConsistency = true
                } label: {
                    Label {
                        Text("Consistency Audit", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.shield")
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help(Text("Consistency Audit", bundle: .module))
                .accessibilityLabel(Text("Open consistency audit", bundle: .module))
            }
        }

        if isLocalSelection {
            ToolbarItem(id: "backups") {
                Button {
                    showingBackups = true
                    Task { await lifecycleModel.refreshBackupsOnly() }
                } label: {
                    Label {
                        Text("Skill Backups", bundle: .module)
                    } icon: {
                        Image(systemName: "archivebox")
                    }
                }
                .disabled(lifecycleModel.isMutating)
                .help(Text("Skill Backups", bundle: .module))
                .accessibilityLabel(backupAccessibilityLabel)
            }
        }

        ToolbarItem(id: "add") {
            Menu {
                Button {
                    showingImport = true
                } label: {
                    Text("Import Skill...", bundle: .module)
                }
                Button {
                    showingAddPath = true
                } label: {
                    Text("Add Custom Path...", bundle: .module)
                }
                Button {
                    showingRepositories = true
                } label: {
                    Text("GitHub Repository...", bundle: .module)
                }
            } label: {
                Label {
                    Text("Add", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .accessibilityLabel(Text("Add", bundle: .module))
            .accessibilityIdentifier("skills.add.menu")
        }
    }

    private var isLocalSelection: Bool {
        switch selection {
        case .managed, .discovered: true
        case .repository, .clawHub, .skillsSh, nil: false
        }
    }

    private var backupAccessibilityLabel: Text {
        if lifecycleModel.availableBackupCount == 0 {
            return Text("Skill Backups", bundle: .module)
        }
        return Text(
            "Skill Backups, \(lifecycleModel.availableBackupCount) available",
            bundle: .module
        )
    }

    private var batchCandidateCount: Int {
        SkillDiscoveryBatchCandidate.canonicalCandidates(from: discoveryModel.items)
            .count(where: \.isSelectable)
    }

    private var canBatchImport: Bool {
        libraryRuntime.readiness == .ready
            && batchCandidateCount > 0
            && !discoveryBatchModel.isExecuting
    }

    private func presentBatchImport() {
        discoveryBatchModel.configure(
            items: discoveryModel.items,
            generation: discoveryModel.publishedRefreshGeneration
        )
        showingDiscoveryBatch = true
    }

    private func applySelection(_ selection: UnifiedSkillSelection?) {
        store.selectedSkillID = selection.managedID
        discoveryModel.selectedItemID = selection.discoveryID
        remoteStore.selectedSkillID = selection.clawHubID
        skillsShStore.selectedResultID = selection.skillsShID
    }

    private func presentRemoteInstallSheet(for skill: RemoteSkill? = nil) {
        if let skill {
            selection = .clawHub(skill.id)
        }
        guard let resolved = skill ?? remoteStore.selectedSkill else { return }
        downloadErrorMessage = nil
        installSkill = resolved
    }
}

private extension Optional where Wrapped == UnifiedSkillSelection {
    var managedID: Skill.ID? {
        guard case .managed(let id) = self else { return nil }
        return id
    }

    var discoveryID: SkillDiscoveryItemID? {
        guard case .discovered(let id) = self else { return nil }
        return id
    }

    var clawHubID: RemoteSkill.ID? {
        guard case .clawHub(let id) = self else { return nil }
        return id
    }

    var skillsShID: SkillsShSearchResultID? {
        guard case .skillsSh(let id) = self else { return nil }
        return id
    }
}
