import AppKit
import SwiftUI

struct SkillSplitView: View {
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(SkillLifecycleViewModel.self) private var lifecycleModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime

    @State private var searchText = ""
    @State private var showingImport = false
    @State private var showingAddPath = false
    @State private var showingBackups = false
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
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent() -> some CustomizableToolbarContent {
        if source == .discovery {
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

        if source != .discovery {
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

    private var searchPrompt: String {
        switch source {
        case .local: "Filter skills"
        case .discovery: "Filter discovered skills"
        case .clawdhub: "Search Clawdhub"
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
            return "Installing Clawdhub Skill"
        }
        if managedRemoteSkillID != nil {
            return "Clawdhub Skill is managed; review installation"
        }
        return "Install Clawdhub Skill"
    }

    @ViewBuilder
    private var openFolderItem: some View {
        if shouldShowOpenFolderMenu {
            Menu {
                ForEach(SkillPlatform.allCases) { platform in
                    if installedPlatformsForSelected.contains(platform) {
                        Button("Open \(platform.rawValue) Folder") {
                            openSelectedSkillFolder(platform: platform)
                        }
                    }
                }
            } label: {
                Label("Open Skill Folder", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .disabled(source != .local)
        } else {
            Button {
                openSelectedSkillFolder(platform: nil)
            } label: {
                Label("Open Skill Folder", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .disabled(source != .local)
        }
    }

    private var shouldShowOpenFolderMenu: Bool {
        installedPlatformsForSelected.count > 1
    }

    private var installedPlatformsForSelected: Set<SkillPlatform> {
        guard source == .local, let slug = store.selectedSkill?.name else { return [] }
        return store.installedPlatforms(for: slug)
    }

    private func openSelectedSkillFolder(platform: SkillPlatform?) {
        guard source == .local else { return }
        let fallbackURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/skills")
        let selected = store.selectedSkill
        let url: URL
        if let platform, let slug = selected?.name {
            if let selected, selected.platform == platform {
                url = selected.folderURL
            } else if let match = store.skills.first(where: {
                SkillContentPath.namesAreEquivalent($0.name, slug)
                    && $0.platform == platform
                    && $0.customPath == selected?.customPath
            }) {
                url = match.folderURL
            } else if let match = store.skills.first(where: {
                SkillContentPath.namesAreEquivalent($0.name, slug) && $0.platform == platform
            }) {
                url = match.folderURL
            } else {
                url = platform.rootURL.appendingPathComponent(slug)
            }
        } else {
            url = selected?.folderURL ?? fallbackURL
        }
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

}

private struct SkillSplitLifecycleModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(SkillDistributionViewModel.self) private var distributionModel
    @Environment(SkillLifecycleViewModel.self) private var lifecycleModel
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
                if newValue != .clawdhub {
                    searchTask?.cancel()
                    searchTask = nil
                }
                if newValue == .local {
                    Task { await store.loadSelectedSkill() }
                }
            }
            .onChange(of: searchText) { _, newValue in
                guard source == .clawdhub else { return }
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await remoteStore.search(query: newValue)
                }
            }
            .onChange(of: libraryRuntime.readiness) { _, _ in
                Task { await synchronizeDiscoveryRuntime() }
            }
            .onChange(of: lifecycleModel.publishedMutationGeneration) { _, _ in
                Task {
                    await store.loadSkills()
                    await discoveryModel.refresh()
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
                }
            }
    }

    private func synchronizeDiscoveryRuntime() async {
        guard libraryRuntime.readiness == .ready else {
            discoveryModel.blockRuntime(
                message: "The managed library is not ready. Resolve its startup diagnostics first."
            )
            distributionModel.blockRuntime(
                message: "The managed library is not ready. Resolve its startup diagnostics first."
            )
            lifecycleModel.blockRuntime(
                message: "The managed library is not ready. Resolve its startup diagnostics first."
            )
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
        await refreshManagedSelection()
    }

    private func refreshManagedSelection() async {
        let observation = discoveryModel.selectedItem?.observation
        let isManaged = observation?.status == .managed
        await distributionModel.refresh(
            skillID: isManaged ? observation?.matchedSkillID : nil,
            displayName: isManaged ? observation?.relativeLocator : nil
        )
        await lifecycleModel.refresh(
            skillID: isManaged ? observation?.matchedSkillID : nil
        )
    }

    private var distributionSelectionKey: String {
        let observation = discoveryModel.selectedItem?.observation
        return [
            observation?.status.rawValue ?? "",
            observation?.matchedSkillID?.directoryName ?? "",
            observation?.relativeLocator ?? "",
            String(discoveryModel.publishedRefreshGeneration),
        ].joined(separator: "\u{0}")
    }
}
