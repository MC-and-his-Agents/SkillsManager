import Foundation
import Observation

nonisolated struct SkillDiscoveryDependencies: Sendable {
    let scan: @Sendable ([SkillDiscoveryRoot]) async throws -> SkillDiscoveryResult
    let preview: @Sendable (
        SkillDiscoveryObservation,
        ManagedSkillImportAction
    ) async throws -> ManagedSkillImportPreview
    let execute: @Sendable (
        ManagedSkillImportToken
    ) async throws -> ManagedSkillImportResult

    static func live(writer: JournaledSSOTWriter) -> Self {
        let session = SkillDiscoverySession(writer: writer)
        return Self(
            scan: { try await session.scan(roots: $0) },
            preview: { try await session.preview(observation: $0, action: $1) },
            execute: { try await session.execute($0) }
        )
    }
}

nonisolated struct SkillDiscoveryItemID: Hashable, Sendable {
    let rootIdentity: ManagedItemIdentity
    let relativeLocatorKey: String
    let rawRelativeLocator: String
}

nonisolated struct SkillDiscoveryRefreshSnapshot: Sendable {
    let generation: UInt64
    let plannedRoots: [SkillDiscoveryRoot]
    let result: SkillDiscoveryResult
    let completedAt: Date
}

nonisolated enum SkillDiscoveryPreflightError: Error, Equatable, LocalizedError, Sendable {
    case runtimeBlocked
    case noUsableResult
    case rootUnavailable

    var errorDescription: String? {
        switch self {
        case .runtimeBlocked:
            "The managed library is not ready."
        case .noUsableResult:
            "No current discovery result is available."
        case .rootUnavailable:
            "One or more required discovery roots are unavailable."
        }
    }
}

nonisolated enum SkillDiscoveryFlowError: Error, Equatable, LocalizedError, Sendable {
    case runtimeBlocked
    case itemUnavailable
    case operationInProgress
    case previewSuperseded

    var errorDescription: String? {
        switch self {
        case .runtimeBlocked:
            "The managed library is not ready."
        case .itemUnavailable:
            "The discovered Skill is no longer available."
        case .operationInProgress:
            "Another import operation is already in progress."
        case .previewSuperseded:
            "Discovery changed before the preview completed. Review the latest result and try again."
        }
    }
}

@MainActor
@Observable final class SkillDiscoveryViewModel {
    enum LoadState: Equatable {
        case blocked(String)
        case idle
        case loading
        case loaded
        case failed(String)
    }

    nonisolated struct Item: Identifiable, Hashable, Sendable {
        let id: SkillDiscoveryItemID
        let observation: SkillDiscoveryObservation

        init(_ observation: SkillDiscoveryObservation) {
            id = SkillDiscoveryItemID(
                rootIdentity: observation.rootIdentity,
                relativeLocatorKey: observation.relativeLocatorKey,
                rawRelativeLocator: observation.rawRelativeLocator
            )
            self.observation = observation
        }

        var allowedActions: Set<ManagedSkillImportAction> {
            ManagedSkillImportService.allowedActions(for: observation)
        }
    }

    nonisolated struct Summary: Equatable, Sendable {
        let plannedRootCount: Int
        let discoveredCount: Int
        let unmanagedCount: Int
        let claimableCount: Int
        let conflictCount: Int
        let failedRootCount: Int
    }

    nonisolated struct PendingImport: Identifiable, Hashable, Sendable {
        let preview: ManagedSkillImportPreview
        let itemID: SkillDiscoveryItemID
        let generation: UInt64

        var id: UUID { preview.token.uuid }
    }

    private nonisolated enum ImportExecution: Sendable {
        case success(ManagedSkillImportResult)
        case invalidated(ManagedSkillImportError)
        case recoverableFailure(String)
    }

    private(set) var loadState: LoadState = .blocked("Preparing the managed library…")
    private(set) var items: [Item] = []
    private(set) var plannedRoots: [SkillDiscoveryRoot] = []
    private(set) var rootDiagnostics: [SkillDiscoveryRootDiagnostic] = []
    private(set) var lastCompletedAt: Date?
    private(set) var summary = Summary(
        plannedRootCount: 0,
        discoveredCount: 0,
        unmanagedCount: 0,
        claimableCount: 0,
        conflictCount: 0,
        failedRootCount: 0
    )
    private(set) var isRefreshing = false
    private(set) var isPreparingPreview = false
    private(set) var pendingImport: PendingImport?
    private(set) var importErrorMessage: String?
    private(set) var importResultMessage: String?
    var selectedItemID: SkillDiscoveryItemID?

    private var dependencies: SkillDiscoveryDependencies?
    private var rootProvider: (@MainActor () -> [SkillDiscoveryRoot])?
    private var runtimeReady = false
    private var requestedGeneration: UInt64 = 0
    private var publishedGeneration: UInt64 = 0
    private var pendingRerun = false
    private var refreshTask: Task<Void, Never>?
    private var importTask: Task<ImportExecution, Never>?
    private var lastSnapshot: SkillDiscoveryRefreshSnapshot?

    var selectedItem: Item? {
        items.first { $0.id == selectedItemID }
    }

    var isImporting: Bool {
        importTask != nil
    }

    @discardableResult
    func activate(
        dependencies: SkillDiscoveryDependencies,
        roots: @escaping @MainActor () -> [SkillDiscoveryRoot]
    ) -> Bool {
        let needsInitialRefresh = !runtimeReady
        self.dependencies = dependencies
        rootProvider = roots
        runtimeReady = true
        loadState = lastSnapshot == nil ? .idle : .loaded
        return needsInitialRefresh
    }

    func blockRuntime(message: String) {
        runtimeReady = false
        requestedGeneration &+= 1
        pendingRerun = false
        refreshTask?.cancel()
        if importTask == nil {
            pendingImport = nil
        }
        loadState = .blocked(message)
        isRefreshing = false
    }

    func refresh() async {
        guard runtimeReady, dependencies != nil, rootProvider != nil else { return }
        requestedGeneration &+= 1
        if let refreshTask {
            pendingRerun = true
            await refreshTask.value
            if runtimeReady, pendingRerun {
                pendingRerun = false
                await refresh()
            }
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRefreshLoop()
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    func preflightRefresh(
        scopes: Set<SkillDiscoveryScope> = []
    ) async throws -> SkillDiscoveryRefreshSnapshot {
        await refresh()
        guard runtimeReady else {
            throw SkillDiscoveryPreflightError.runtimeBlocked
        }
        guard loadState == .loaded,
              let snapshot = lastSnapshot,
              snapshot.generation == publishedGeneration else {
            throw SkillDiscoveryPreflightError.noUsableResult
        }
        let relevantDiagnostics = snapshot.result.rootDiagnostics.filter {
            scopes.isEmpty || scopes.contains($0.root.scope)
        }
        guard relevantDiagnostics.isEmpty else {
            throw SkillDiscoveryPreflightError.rootUnavailable
        }
        return snapshot
    }

    func prepareImport(
        itemID: SkillDiscoveryItemID,
        action: ManagedSkillImportAction
    ) async throws {
        guard runtimeReady, let dependencies else {
            throw SkillDiscoveryFlowError.runtimeBlocked
        }
        guard importTask == nil, !isPreparingPreview else {
            throw SkillDiscoveryFlowError.operationInProgress
        }
        guard let item = items.first(where: { $0.id == itemID }),
              ManagedSkillImportService.allowedActions(for: item.observation).contains(action) else {
            throw SkillDiscoveryFlowError.itemUnavailable
        }

        isPreparingPreview = true
        importErrorMessage = nil
        importResultMessage = nil
        let generation = publishedGeneration
        defer { isPreparingPreview = false }
        let preview = try await dependencies.preview(item.observation, action)
        guard runtimeReady, generation == publishedGeneration else {
            throw SkillDiscoveryFlowError.previewSuperseded
        }
        pendingImport = PendingImport(
            preview: preview,
            itemID: itemID,
            generation: generation
        )
    }

    func cancelPendingImport() {
        guard importTask == nil else { return }
        pendingImport = nil
    }

    func confirmPendingImport() async {
        guard runtimeReady, let dependencies, let pendingImport else {
            importErrorMessage = SkillDiscoveryFlowError.runtimeBlocked.localizedDescription
            return
        }
        if let importTask {
            _ = await importTask.value
            return
        }

        importErrorMessage = nil
        importResultMessage = nil
        let task = Task {
            do {
                return ImportExecution.success(
                    try await dependencies.execute(pendingImport.preview.token)
                )
            } catch let error as ManagedSkillImportError {
                return ImportExecution.invalidated(error)
            } catch {
                return ImportExecution.recoverableFailure(error.localizedDescription)
            }
        }
        importTask = task
        let execution = await task.value
        importTask = nil

        switch execution {
        case .success(let result):
            self.pendingImport = nil
            importResultMessage = Self.successMessage(for: result.disposition)
            await refresh()
        case .invalidated(let error):
            self.pendingImport = nil
            importErrorMessage = Self.message(for: error)
            await refresh()
        case .recoverableFailure(let message):
            importErrorMessage = message
        }
    }

    private func runRefreshLoop() async {
        isRefreshing = true
        defer { isRefreshing = false }

        while runtimeReady, !Task.isCancelled,
              let dependencies, let rootProvider {
            pendingRerun = false
            let generation = requestedGeneration
            let roots = rootProvider()
            plannedRoots = roots
            summary = Summary(
                plannedRootCount: roots.count,
                discoveredCount: summary.discoveredCount,
                unmanagedCount: summary.unmanagedCount,
                claimableCount: summary.claimableCount,
                conflictCount: summary.conflictCount,
                failedRootCount: summary.failedRootCount
            )
            if lastSnapshot == nil {
                loadState = .loading
            }

            do {
                let result = try await dependencies.scan(roots)
                guard runtimeReady else { return }
                if generation != requestedGeneration || pendingRerun {
                    continue
                }
                publish(
                    SkillDiscoveryRefreshSnapshot(
                        generation: generation,
                        plannedRoots: roots,
                        result: result,
                        completedAt: Date()
                    )
                )
            } catch is CancellationError {
                if runtimeReady,
                   (generation != requestedGeneration || pendingRerun) {
                    continue
                }
                return
            } catch {
                guard runtimeReady else { return }
                if generation != requestedGeneration || pendingRerun {
                    continue
                }
                loadState = .failed(error.localizedDescription)
            }

            if generation == requestedGeneration, !pendingRerun {
                return
            }
        }
    }

    private func publish(_ snapshot: SkillDiscoveryRefreshSnapshot) {
        lastSnapshot = snapshot
        publishedGeneration = snapshot.generation
        let previousSelection = selectedItemID
        plannedRoots = snapshot.plannedRoots
        items = snapshot.result.observations.map(Item.init)
        rootDiagnostics = snapshot.result.rootDiagnostics
        lastCompletedAt = snapshot.completedAt
        summary = Summary(
            plannedRootCount: snapshot.plannedRoots.count,
            discoveredCount: items.count,
            unmanagedCount: items.count { $0.observation.status == .unmanaged },
            claimableCount: items.count { $0.observation.status == .claimable },
            conflictCount: items.count { $0.observation.status == .conflict },
            failedRootCount: rootDiagnostics.count
        )
        selectedItemID = previousSelection.flatMap { selection in
            items.contains(where: { $0.id == selection }) ? selection : nil
        } ?? items.first?.id
        if importTask == nil {
            pendingImport = nil
        }
        loadState = .loaded
    }

    private static func successMessage(
        for disposition: ManagedSkillImportDisposition
    ) -> String {
        switch disposition {
        case .created:
            "The Skill was imported into the managed library."
        case .claimed:
            "The existing managed Skill was linked to this local source."
        case .alreadyManaged:
            "This Skill was already managed."
        }
    }

    private static func message(for error: ManagedSkillImportError) -> String {
        switch error {
        case .actionNotAllowed:
            "This action is no longer available."
        case .invalidObservation:
            "The discovery result is no longer valid."
        case .tokenExpired:
            "The preview expired."
        case .sourceChanged:
            "The source changed after preview."
        case .conflict:
            "The source now conflicts with another managed Skill."
        }
    }
}
