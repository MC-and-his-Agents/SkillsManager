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
    @State private var selection: UnifiedSkillSelection?
    @State private var searchTask: Task<Void, Never>?
    @State private var showingImport = false
    @State private var showingAddPath = false
    @State private var showingBackups = false
    @State private var showingConsistency = false
    @State private var showingBatchUpdates = false
    @State private var downloadErrorMessage: String?
    @State private var isDownloadingRemote = false
    @State private var didDownloadRemote = false
    @State private var installSkill: RemoteSkill?
    @State private var managedRemoteSkillID: SkillID?

    private var query: String {
        normalizedSkillSearchQuery(searchText)
    }

    private var filteredSkills: [Skill] {
        guard !query.isEmpty else { return store.skills }
        return store.skills.filter { skill in
            skill.displayName.localizedCaseInsensitiveContains(query)
                || skill.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredDiscoveryItems: [SkillDiscoveryViewModel.Item] {
        let canonical = visibleDiscoveryItems(
            discoveryModel.items,
            managedSkillIDs: Set(store.skills.map(\.managedSkillID))
        )
        guard !query.isEmpty else { return canonical }
        return canonical.filter { item in
            let observation = item.observation
            return observation.relativeLocator.localizedCaseInsensitiveContains(query)
                || observation.scopeSummary.localizedCaseInsensitiveContains(query)
                || observation.displayURLs.contains {
                    $0.path.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var visibleSelections: Set<UnifiedSkillSelection> {
        var values = Set(filteredSkills.map { UnifiedSkillSelection.managed($0.id) })
        values.formUnion(filteredDiscoveryItems.map {
            UnifiedSkillSelection.discovered($0.id)
        })
        if query.isEmpty {
            values.formUnion(visibleRemoteSkillSelections(
                clawHubSkills: remoteStore.latestSkills,
                clawHubLoaded: remoteStore.latestState == .loaded
            ))
        } else {
            values.formUnion(visibleRemoteSkillSelections(
                clawHubSkills: remoteStore.searchResults,
                clawHubLoaded: remoteStore.searchState == .loaded,
                skillsShItems: skillsShStore.items,
                skillsShLoaded: skillsShStore.searchState == .loaded
            ))
        }
        return values
    }

    var body: some View {
        NavigationSplitView {
            SkillListView(
                localSkills: filteredSkills,
                discoveryItems: filteredDiscoveryItems,
                query: query,
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
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Skills")
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
        .sheet(isPresented: $showingBatchUpdates) {
            SkillBatchUpdateView().environment(batchUpdateModel)
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
        .task(id: remoteStore.selectedSkillID) {
            await refreshManagedRemoteSkill()
        }
        .onChange(of: selection) { _, newValue in
            applySelection(newValue)
        }
        .onChange(of: visibleSelections) { _, visible in
            selection = reconciledSkillSelection(selection, visibleSelections: visible)
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

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .managed:
            SkillDetailView()
        case .discovered:
            SkillDiscoveryDetailView()
        case .clawHub:
            RemoteSkillDetailView()
        case .skillsSh:
            SkillsShSearchDetailView()
        case nil:
            ContentUnavailableView(
                "Select a skill",
                systemImage: "sparkles",
                description: Text("Pick a skill from the list.")
            )
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
        if isLocalSelection || selection == nil {
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

        if isLocalSelection {
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
                .accessibilityLabel(backupAccessibilityLabel)
            }
        }

        if case .managed = selection {
            ToolbarItem(id: "batch-updates") {
                Button {
                    configureBatchUpdates()
                    showingBatchUpdates = true
                } label: {
                    Label("Batch Updates", systemImage: "arrow.down.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(batchUpdatesDisabled)
                .help(batchUpdateHelp)
                .accessibilityLabel("Open Batch Updates")
                .accessibilityValue(batchUpdateHelp)
                .accessibilityHint(batchUpdateHelp)
            }
        }

        if case .clawHub = selection {
            ToolbarItem(id: "download") {
                Button { presentRemoteInstallSheet() } label: { downloadLabel }
                    .labelStyle(.iconOnly)
                    .disabled(isDownloadingRemote || remoteStore.selectedSkill == nil)
                    .accessibilityLabel(remoteInstallAccessibilityLabel)
            }
        }

        if case .managed = selection {
            ToolbarItem(id: "open") {
                Button { openSelectedSkillFolder() } label: {
                    Label("Open Skill Folder", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .disabled(store.selectedSkill == nil)
            }
        }

        if selection == nil || isManagedSelection {
            ToolbarItem(id: "add") {
                Menu {
                    Button("Import Skill...") { showingImport = true }
                    Button("Add Custom Path...") { showingAddPath = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private var isLocalSelection: Bool {
        switch selection {
        case .managed, .discovered: true
        case .clawHub, .skillsSh, nil: false
        }
    }

    private var isManagedSelection: Bool {
        if case .managed = selection { return true }
        return false
    }

    private var backupAccessibilityLabel: String {
        lifecycleModel.availableBackupCount == 0
            ? "Skill Backups"
            : "Skill Backups, \(lifecycleModel.availableBackupCount) available"
    }

    private var batchUpdatesDisabled: Bool {
        store.skills.isEmpty
            || libraryRuntime.readiness != .ready
            || batchUpdateModel.operationActive
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

    private func configureBatchUpdates() {
        batchUpdateModel.configure(store.skills.map {
            SkillBatchUpdateCatalogItem(
                skillID: $0.managedSkillID,
                displayName: $0.displayName
            )
        })
    }

    private func applySelection(_ selection: UnifiedSkillSelection?) {
        store.selectedSkillID = selection.managedID
        discoveryModel.selectedItemID = selection.discoveryID
        remoteStore.selectedSkillID = selection.clawHubID
        skillsShStore.selectedResultID = selection.skillsShID
    }

    @ViewBuilder
    private var downloadLabel: some View {
        if isDownloadingRemote {
            ProgressView()
        } else if managedRemoteSkillID != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }

    private var remoteInstallAccessibilityLabel: String {
        if isDownloadingRemote { return "Installing ClawHub Skill" }
        if managedRemoteSkillID != nil {
            return "ClawHub Skill is managed; review installation"
        }
        return "Install ClawHub Skill"
    }

    private func openSelectedSkillFolder() {
        guard let url = store.selectedSkill?.folderURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func presentRemoteInstallSheet(for skill: RemoteSkill? = nil) {
        if let skill {
            selection = .clawHub(skill.id)
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
              ) else { return }
        let provenance = try? await writer.providerProvenance(identity)
        guard remoteStore.selectedSkillID == selectedID else { return }
        managedRemoteSkillID = provenance?.skillID
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
