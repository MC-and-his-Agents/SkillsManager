import SwiftUI

struct SkillSplitLifecycleModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillsShSearchStore.self) private var skillsShStore
    @Environment(CustomRepositoryViewModel.self) private var customRepositoryModel
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(SkillDiscoveryBatchViewModel.self) private var discoveryBatchModel
    @Environment(SkillDistributionViewModel.self) private var distributionModel
    @Environment(SkillUpdateCheckViewModel.self) private var updateCheckModel
    @Environment(SkillBatchUpdateViewModel.self) private var batchUpdateModel
    @Environment(SkillLifecycleViewModel.self) private var lifecycleModel
    @Environment(SkillConsistencyViewModel.self) private var consistencyModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime
    @Environment(\.skillsManagerHomeURL) private var homeURL
    @Environment(\.skillsManagerGitHubClient) private var githubClient

    @Binding var selection: UnifiedSkillSelection?
    @Binding var searchText: String
    @Binding var searchTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task {
                async let local: Void = store.loadSkills()
                async let latest: Void = remoteStore.loadLatest()
                _ = await (local, latest)
                selectInitialLocalSkill()
            }
            .task {
                await synchronizeDiscoveryRuntime()
                selectInitialLocalSkill()
            }
            .onChange(of: selection) { _, _ in
                Task { await refreshManagedSelection() }
            }
            .onChange(of: store.selectedSkillID) { _, newValue in
                synchronizeManagedSelection(newValue)
                Task { await store.loadSelectedSkill() }
            }
            .onChange(of: remoteStore.selectedSkillID) { _, newValue in
                synchronizeClawHubSelection(newValue)
                Task { await remoteStore.loadSelectedSkill() }
            }
            .onChange(of: discoveryModel.selectedItemID) { _, newValue in
                synchronizeDiscoverySelection(newValue)
            }
            .onChange(of: discoveryModel.publishedRefreshGeneration) { _, generation in
                discoveryBatchModel.invalidate(generation: generation)
            }
            .onChange(of: skillsShStore.selectedResultID) { _, newValue in
                synchronizeSkillsShSelection(newValue)
            }
            .onChange(of: distributionModel.publishedForkSelectionGeneration) { _, _ in
                Task { await selectRequestedFork() }
            }
            .onChange(of: searchText) { _, newValue in
                scheduleRemoteSearch(query: newValue)
            }
            .onChange(of: libraryRuntime.readiness) { _, _ in
                Task { await synchronizeDiscoveryRuntime() }
            }
            .onChange(of: lifecycleModel.publishedMutationGeneration) { _, _ in
                Task {
                    await store.loadSkills()
                    await discoveryModel.refresh()
                    await refreshManagedSelection(preserveFeedback: true)
                    await consistencyModel.refreshIfLoaded()
                }
            }
            .onChange(of: scenePhase) { oldValue, newValue in
                guard oldValue != .active,
                      newValue == .active,
                      libraryRuntime.readiness == .ready else { return }
                Task {
                    await discoveryModel.refresh()
                    await consistencyModel.refreshIfLoaded()
                    await updateCheckModel.refreshCurrent()
                }
            }
    }

    private func synchronizeDiscoveryRuntime() async {
        guard libraryRuntime.readiness == .ready else {
            await blockRuntime(message: libraryRuntime.blockingMessage)
            return
        }
        guard let writer = store.persistence else {
            await blockRuntime(message: libraryRuntime.blockingMessage)
            return
        }
        let needsInitialRefresh = discoveryModel.activate(
            dependencies: .live(writer: writer),
            roots: {
                SkillDiscoveryRootPlan.make(
                    homeURL: homeURL,
                    customPaths: store.customPaths
                )
            }
        )
        if needsInitialRefresh { await discoveryModel.refresh() }
        discoveryBatchModel.activate(dependencies: .live(writer: writer))
        distributionModel.activate(dependencies: .live(writer: writer))
        lifecycleModel.activate(dependencies: .live(writer: writer))
        consistencyModel.activate(dependencies: .live(writer: writer))
        updateCheckModel.activate(writer: writer, remote: remoteStore.client)
        batchUpdateModel.activate(writer: writer, remote: remoteStore.client)
        let needsRepositoryRefresh = customRepositoryModel.activate(
            dependencies: .live(writer: writer, client: githubClient)
        )
        if needsRepositoryRefresh { await customRepositoryModel.loadAndRefresh() }
        await refreshManagedSelection()
        await consistencyModel.refreshIfLoaded()
    }

    private func blockRuntime(message: String) async {
        store.blockRuntime(message: message)
        discoveryModel.blockRuntime(message: message)
        discoveryBatchModel.blockRuntime(message: message)
        distributionModel.blockRuntime(message: message)
        lifecycleModel.blockRuntime(message: message)
        consistencyModel.blockRuntime(message: message)
        batchUpdateModel.blockRuntime(message: message)
        customRepositoryModel.blockRuntime(message: message)
        await updateCheckModel.blockRuntime(message: message)
    }

    private func scheduleRemoteSearch(query rawQuery: String) {
        let query = normalizedSkillSearchQuery(rawQuery)
        searchTask?.cancel()
        searchTask = Task {
            await clearRemoteSearches()
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            async let clawHub: Void = remoteStore.search(query: query)
            async let skillsSh: Void = skillsShStore.search(query: query)
            _ = await (clawHub, skillsSh)
        }
    }

    private func clearRemoteSearches() async {
        async let clawHub: Void = remoteStore.search(query: "")
        async let skillsSh: Void = skillsShStore.search(query: "")
        _ = await (clawHub, skillsSh)
    }

    private func refreshManagedSelection(preserveFeedback: Bool = false) async {
        let current = managedSelection
        await refreshManagedSkillSelection(
            current,
            distributionModel: distributionModel,
            lifecycleModel: lifecycleModel,
            isCurrent: { current == managedSelection },
            preserveFeedback: preserveFeedback
        )
        guard current == managedSelection else { return }
        await updateCheckModel.refresh(skillID: current?.skillID)
    }

    private func selectRequestedFork() async {
        guard let childSkillID = distributionModel.requestedForkChildSkillID else { return }
        await store.loadSkills()
        await discoveryModel.refresh()
        guard distributionModel.requestedForkChildSkillID == childSkillID else { return }
        guard let skill = store.skills.first(where: { $0.managedSkillID == childSkillID }) else {
            distributionModel.reportForkSelectionFailure(childSkillID)
            return
        }
        selection = .managed(skill.id)
        distributionModel.acknowledgeForkSelection(childSkillID)
    }

    private func selectInitialLocalSkill() {
        guard selection == nil else { return }
        if let id = store.selectedSkillID {
            selection = .managed(id)
        } else if let id = discoveryModel.selectedItemID {
            selection = .discovered(id)
        }
    }

    private func synchronizeManagedSelection(_ id: Skill.ID?) {
        guard selection == nil || selection?.isManaged == true else { return }
        selection = id.map(UnifiedSkillSelection.managed)
    }

    private func synchronizeDiscoverySelection(_ id: SkillDiscoveryItemID?) {
        guard selection == nil || selection?.isDiscovered == true else { return }
        selection = id.map(UnifiedSkillSelection.discovered)
    }

    private func synchronizeClawHubSelection(_ id: RemoteSkill.ID?) {
        guard selection == nil || selection?.isClawHub == true else { return }
        selection = id.map(UnifiedSkillSelection.clawHub)
    }

    private func synchronizeSkillsShSelection(_ id: SkillsShSearchResultID?) {
        guard selection == nil || selection?.isSkillsSh == true else { return }
        selection = id.map(UnifiedSkillSelection.skillsSh)
    }

    private var managedSelection: ManagedSkillSelection? {
        switch selection {
        case .managed:
            guard let skill = store.selectedSkill else { return nil }
            return ManagedSkillSelection(
                skillID: skill.managedSkillID,
                displayName: skill.displayName
            )
        case .discovered:
            guard let observation = discoveryModel.selectedItem?.observation,
                  observation.status == .managed,
                  let skillID = observation.matchedSkillID else { return nil }
            return ManagedSkillSelection(
                skillID: skillID,
                displayName: observation.relativeLocator
            )
        case .repository, .clawHub, .skillsSh, nil:
            return nil
        }
    }
}

private extension UnifiedSkillSelection {
    var isManaged: Bool {
        if case .managed = self { return true }
        return false
    }

    var isDiscovered: Bool {
        if case .discovered = self { return true }
        return false
    }

    var isClawHub: Bool {
        if case .clawHub = self { return true }
        return false
    }

    var isSkillsSh: Bool {
        if case .skillsSh = self { return true }
        return false
    }
}
