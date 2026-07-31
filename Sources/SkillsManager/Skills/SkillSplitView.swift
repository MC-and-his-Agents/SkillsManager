import AppKit
import SwiftUI

struct SkillSplitView: View {
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillsShSearchStore.self) private var skillsShStore
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(SkillBatchUpdateViewModel.self) private var batchUpdateModel
    @Environment(SkillLifecycleViewModel.self) private var lifecycleModel
    @Environment(SkillConsistencyViewModel.self) private var consistencyModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime

    @State private var searchText = ""
    @State private var showingImport = false
    @State private var showingAddPath = false
    @State private var showingBackups = false
    @State private var showingConsistency = false
    @State private var showingBatchUpdates = false
    @State private var source: SkillSource = .local
    @State private var downloadErrorMessage: String?
    @State private var isDownloadingRemote = false
    @State private var didDownloadRemote = false
    @State private var installSkill: RemoteSkill?
    @State private var managedRemoteSkillID: SkillID?
    @State private var searchTask: Task<Void, Never>?

    private var filteredSkills: [Skill] {
        guard !searchText.isEmpty else { return store.skills }
        return store.skills.filter { skill in
            skill.displayName.localizedCaseInsensitiveContains(searchText)
                || skill.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredDiscoveryItems: [SkillDiscoveryViewModel.Item] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return discoveryModel.items }
        return discoveryModel.items.filter { item in
            let observation = item.observation
            return observation.relativeLocator.localizedCaseInsensitiveContains(query)
                || observation.scopeSummary.localizedCaseInsensitiveContains(query)
                || observation.displayURLs.contains {
                    $0.path.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        splitView
            .modifier(
                SkillSplitLifecycleModifier(
                    source: $source,
                    searchText: $searchText,
                    searchTask: $searchTask
                )
            )
            .toolbar(id: "main-toolbar") {
                toolbarContent()
            }
            .sheet(isPresented: $showingImport) {
                ImportSkillView()
                    .environment(store)
            }
            .sheet(isPresented: $showingAddPath) {
                AddCustomPathView()
                    .environment(store)
            }
            .sheet(isPresented: $showingBackups) {
                SkillBackupLibraryView()
                    .environment(lifecycleModel)
            }
            .sheet(isPresented: $showingConsistency) {
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
            .sheet(isPresented: $showingBatchUpdates) {
                SkillBatchUpdateView()
                    .environment(batchUpdateModel)
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
            .searchable(
                text: $searchText,
                placement: .sidebar,
                prompt: searchPrompt
            )
            .task(id: remoteStore.selectedSkillID) {
                await refreshManagedRemoteSkill()
            }
            .onChange(of: didDownloadRemote) { _, installed in
                guard installed else { return }
                Task {
                    await refreshManagedRemoteSkill()
                    didDownloadRemote = false
                }
            }
            .onChange(of: libraryRuntime.readiness) { _, _ in
                Task { await refreshManagedRemoteSkill() }
            }
            .onChange(of: lifecycleModel.publishedMutationGeneration) { _, _ in
                Task { await refreshManagedRemoteSkill() }
            }
            .onChange(of: batchUpdateModel.state) { _, newValue in
                guard newValue == .completed else { return }
                Task {
                    await store.loadSkills()
                    await discoveryModel.refresh()
                }
            }
    }

    private var splitView: some View {
        NavigationSplitView {
            listView
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var listView: some View {
        switch source {
        case .local, .clawdhub:
            SkillListView(
                localSkills: filteredSkills,
                remoteLatestSkills: remoteStore.latestSkills,
                remoteSearchResults: remoteStore.searchResults,
                remoteSearchState: remoteStore.searchState,
                remoteLatestState: remoteStore.latestState,
                remoteQuery: searchText,
                installedSkillPlatforms: store.installedSkillPlatformIndex,
                onInstallRemoteSkill: { skill in
                    presentRemoteInstallSheet(for: skill)
                },
                source: $source,
                localSelection: localSelectionBinding,
                remoteSelection: remoteSelectionBinding
            )
        case .discovery:
            SkillDiscoverySidebarView(
                items: filteredDiscoveryItems,
                source: $source
            )
        case .skillsSh:
            SkillsShSearchSidebarView(
                searchText: searchText,
                onRetrySearch: scheduleSkillsShSearch,
                onLoadMore: loadMoreSkillsShResults,
                source: $source
            )
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch source {
        case .local:
            SkillDetailView()
        case .discovery:
            SkillDiscoveryDetailView()
        case .clawdhub:
            RemoteSkillDetailView()
        case .skillsSh:
            SkillsShSearchDetailView()
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent() -> some CustomizableToolbarContent {
        if source != .skillsSh {
            ToolbarItem(id: "consistency") {
                Button {
                    showingConsistency = true
                } label: {
                    Label("Consistency Audit", systemImage: "checkmark.shield")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Consistency Audit")
                .accessibilityLabel("Open consistency audit")
            }
        }

        if source != .clawdhub && source != .skillsSh {
            ToolbarItem(id: "backups") {
                Button {
                    showingBackups = true
                    Task { await lifecycleModel.refreshBackupsOnly() }
                } label: {
                    Label("Skill Backups", systemImage: "archivebox")
                        .labelStyle(.iconOnly)
                }
                .disabled(lifecycleModel.isMutating)
                .help("Skill Backups")
                .accessibilityLabel(
                    lifecycleModel.availableBackupCount == 0
                        ? "Skill Backups"
                        : "Skill Backups, \(lifecycleModel.availableBackupCount) available"
                )
            }
        }

        if source == .local {
            ToolbarItem(id: "batch-updates") {
                Button {
                    batchUpdateModel.configure(
                        store.skills.map {
                            SkillBatchUpdateCatalogItem(
                                skillID: $0.managedSkillID,
                                displayName: $0.displayName
                            )
                        }
                    )
                    showingBatchUpdates = true
                } label: {
                    Label("Batch Updates", systemImage: "arrow.down.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(
                    store.skills.isEmpty
                        || libraryRuntime.readiness != .ready
                        || batchUpdateModel.operationActive
                )
                .help(batchUpdateHelp)
                .accessibilityLabel("Open Batch Updates")
                .accessibilityValue(batchUpdateHelp)
                .accessibilityHint(batchUpdateHelp)
            }
        }

        if source == .clawdhub {
            ToolbarItem(id: "download") {
                Button {
                    presentRemoteInstallSheet()
                } label: {
                    downloadLabel
                }
                .labelStyle(.iconOnly)
                .disabled(isDownloadingRemote || !canDownloadRemoteSkill)
                .accessibilityLabel(remoteInstallAccessibilityLabel)
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
            }

        }

        if source != .discovery && source != .skillsSh {
            ToolbarItem(id: "open") {
                openFolderItem
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
            }

            ToolbarItem(id: "add") {
                Menu {
                    Button("Import Skill...") {
                        showingImport = true
                    }
                    Button("Add Custom Path...") {
                        showingAddPath = true
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private var batchUpdateHelp: String {
        if libraryRuntime.readiness != .ready {
            return "Batch updates are unavailable until the managed library is ready."
        }
        if store.skills.isEmpty {
            return "Import a managed Skill before checking for batch updates."
        }
        if batchUpdateModel.operationActive {
            return "A batch update is already running."
        }
        return "Check all managed Skills for updates."
    }

    private var searchPrompt: String {
        switch source {
        case .local: "Filter skills"
        case .discovery: "Filter discovered skills"
        case .clawdhub: "Search ClawHub"
        case .skillsSh: "Search skills.sh"
        }
    }

    private var canDownloadRemoteSkill: Bool {
        remoteStore.selectedSkill != nil
    }

    private var localSelectionBinding: Binding<Skill.ID?> {
        Binding(
            get: { store.selectedSkillID },
            set: { store.selectedSkillID = $0 }
        )
    }

    private var remoteSelectionBinding: Binding<RemoteSkill.ID?> {
        Binding(
            get: { remoteStore.selectedSkillID },
            set: { remoteStore.selectedSkillID = $0 }
        )
    }

    @ViewBuilder
    private var downloadLabel: some View {
        if isDownloadingRemote {
            ProgressView()
        } else if managedRemoteSkillID != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }

    private var remoteInstallAccessibilityLabel: String {
        if isDownloadingRemote {
            return "Installing ClawHub Skill"
        }
        if managedRemoteSkillID != nil {
            return "ClawHub Skill is managed; review installation"
        }
        return "Install ClawHub Skill"
    }

    @ViewBuilder
    private var openFolderItem: some View {
        Button {
            openSelectedSkillFolder()
        } label: {
            Label("Open Skill Folder", systemImage: "folder")
        }
        .labelStyle(.iconOnly)
        .disabled(source != .local || store.selectedSkill == nil)
    }

    private func openSelectedSkillFolder() {
        guard source == .local, let url = store.selectedSkill?.folderURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func presentRemoteInstallSheet(for skill: RemoteSkill? = nil) {
        if let skill {
            remoteStore.selectedSkillID = skill.id
        }
        guard let resolved = skill ?? remoteStore.selectedSkill else { return }
        downloadErrorMessage = nil
        installSkill = resolved
    }

    private func refreshManagedRemoteSkill() async {
        let selectedID = remoteStore.selectedSkillID
        managedRemoteSkillID = nil
        guard let skill = remoteStore.selectedSkill,
              let writer = store.persistence,
              let slug = try? DefaultDistributionSlug(validating: skill.slug),
              let identity = try? ProviderAliasIdentity(
                provider: "clawdhub",
                identifier: slug.value
              ) else {
            managedRemoteSkillID = nil
            return
        }
        let provenance = try? await writer.providerProvenance(identity)
        guard remoteStore.selectedSkillID == selectedID else { return }
        managedRemoteSkillID = provenance?.skillID
    }

    private func scheduleSkillsShSearch() {
        searchTask?.cancel()
        skillsShStore.cancel()
        searchTask = Task {
            await skillsShStore.search(query: searchText)
        }
    }

    private func loadMoreSkillsShResults() {
        searchTask?.cancel()
        searchTask = Task {
            await skillsShStore.loadNextPage()
        }
    }

}

private struct SkillSplitLifecycleModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillsShSearchStore.self) private var skillsShStore
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(SkillDistributionViewModel.self) private var distributionModel
    @Environment(SkillUpdateCheckViewModel.self) private var updateCheckModel
    @Environment(SkillBatchUpdateViewModel.self) private var batchUpdateModel
    @Environment(SkillLifecycleViewModel.self) private var lifecycleModel
    @Environment(SkillConsistencyViewModel.self) private var consistencyModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime

    @Binding var source: SkillSource
    @Binding var searchText: String
    @Binding var searchTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task {
                await store.loadSkills()
                await remoteStore.loadLatest()
            }
            .task {
                await synchronizeDiscoveryRuntime()
            }
            .onChange(of: store.selectedSkillID) { _, _ in
                Task { await store.loadSelectedSkill() }
            }
            .onChange(of: remoteStore.selectedSkillID) { _, _ in
                Task { await remoteStore.loadSelectedSkill() }
            }
            .onChange(of: distributionSelectionKey) { _, _ in
                Task { await refreshManagedSelection() }
            }
            .onChange(of: source) { _, newValue in
                searchTask?.cancel()
                searchTask = nil
                skillsShStore.cancel()
                if newValue == .local {
                    Task { await store.loadSelectedSkill() }
                }
                scheduleRemoteSearch(for: newValue, query: searchText)
            }
            .onChange(of: distributionModel.publishedForkSelectionGeneration) { _, _ in
                Task { await selectRequestedFork() }
            }
            .onChange(of: searchText) { _, newValue in
                scheduleRemoteSearch(for: source, query: newValue)
            }
            .onChange(of: libraryRuntime.readiness) { _, _ in
                Task { await synchronizeDiscoveryRuntime() }
            }
            .onChange(of: lifecycleModel.publishedMutationGeneration) { _, _ in
                Task {
                    await store.loadSkills()
                    await discoveryModel.refresh()
                    await refreshManagedSelection()
                    await consistencyModel.refreshIfLoaded()
                }
            }
            .onChange(of: scenePhase) { oldValue, newValue in
                guard oldValue != .active,
                      newValue == .active,
                      libraryRuntime.readiness == .ready else {
                    return
                }
                Task {
                    await discoveryModel.refresh()
                    await consistencyModel.refreshIfLoaded()
                    await updateCheckModel.refreshCurrent()
                }
            }
    }

    private func synchronizeDiscoveryRuntime() async {
        guard libraryRuntime.readiness == .ready else {
            let message = libraryRuntime.blockingMessage
            discoveryModel.blockRuntime(
                message: message
            )
            distributionModel.blockRuntime(
                message: message
            )
            lifecycleModel.blockRuntime(
                message: message
            )
            consistencyModel.blockRuntime(
                message: message
            )
            await updateCheckModel.blockRuntime(
                message: message
            )
            batchUpdateModel.blockRuntime(message: message)
            return
        }
        guard let writer = store.persistence else {
            discoveryModel.blockRuntime(
                message: "The managed library session is unavailable."
            )
            distributionModel.blockRuntime(
                message: "The managed library session is unavailable."
            )
            lifecycleModel.blockRuntime(
                message: "The managed library session is unavailable."
            )
            consistencyModel.blockRuntime(
                message: "The managed library session is unavailable."
            )
            await updateCheckModel.blockRuntime(
                message: "The managed library session is unavailable."
            )
            batchUpdateModel.blockRuntime(
                message: "The managed library session is unavailable."
            )
            return
        }
        let needsInitialRefresh = discoveryModel.activate(
            dependencies: .live(writer: writer),
            roots: {
                SkillDiscoveryRootPlan.make(
                    homeURL: FileManager.default.homeDirectoryForCurrentUser,
                    customPaths: store.customPaths
                )
            }
        )
        if needsInitialRefresh {
            await discoveryModel.refresh()
        }
        distributionModel.activate(dependencies: .live(writer: writer))
        lifecycleModel.activate(dependencies: .live(writer: writer))
        consistencyModel.activate(dependencies: .live(writer: writer))
        updateCheckModel.activate(writer: writer, remote: remoteStore.client)
        batchUpdateModel.activate(writer: writer, remote: remoteStore.client)
        await refreshManagedSelection()
        await consistencyModel.refreshIfLoaded()
    }

    private func scheduleRemoteSearch(for source: SkillSource, query: String) {
        guard source == .clawdhub || source == .skillsSh else { return }
        searchTask?.cancel()
        if source == .skillsSh {
            skillsShStore.cancel()
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            switch source {
            case .clawdhub:
                await remoteStore.search(query: query)
            case .skillsSh:
                await skillsShStore.search(query: query)
            case .local, .discovery:
                break
            }
        }
    }

    private func refreshManagedSelection() async {
        let selection = managedSelection
        await refreshManagedSkillSelection(
            selection,
            distributionModel: distributionModel,
            lifecycleModel: lifecycleModel,
            isCurrent: { selection == managedSelection }
        )
        guard selection == managedSelection else { return }
        await updateCheckModel.refresh(skillID: selection?.skillID)
    }

    private func selectRequestedFork() async {
        guard let childSkillID = distributionModel.requestedForkChildSkillID else {
            return
        }
        await store.loadSkills()
        await discoveryModel.refresh()
        guard distributionModel.requestedForkChildSkillID == childSkillID else {
            return
        }
        guard let item = discoveryModel.items.first(where: {
            $0.observation.status == .managed
                && $0.observation.matchedSkillID == childSkillID
        }) else {
            distributionModel.reportForkSelectionFailure(childSkillID)
            return
        }
        source = .discovery
        discoveryModel.selectedItemID = item.id
        distributionModel.acknowledgeForkSelection(childSkillID)
    }

    private var distributionSelectionKey: String {
        let selection = managedSelection
        return [
            source.rawValue,
            store.selectedSkillID ?? "",
            selection?.skillID.directoryName ?? "",
            selection?.displayName ?? "",
            String(discoveryModel.publishedRefreshGeneration),
        ].joined(separator: "\u{0}")
    }

    private var managedSelection: ManagedSkillSelection? {
        let local: ManagedSkillSelection?
        if let skill = store.selectedSkill, skill.id == store.selectedSkillID {
            local = ManagedSkillSelection(
                skillID: skill.managedSkillID,
                displayName: skill.displayName
            )
        } else {
            local = nil
        }

        let discovery: ManagedSkillSelection?
        if let observation = discoveryModel.selectedItem?.observation,
           observation.status == .managed,
           let skillID = observation.matchedSkillID {
            discovery = ManagedSkillSelection(
                skillID: skillID,
                displayName: observation.relativeLocator
            )
        } else {
            discovery = nil
        }

        return ManagedSkillSelection.resolve(
            source: source,
            local: local,
            discovery: discovery
        )
    }
}
