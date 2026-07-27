import Darwin
import Foundation
import Observation

@MainActor
@Observable final class SkillDistributionViewModel {
    enum LoadState: Equatable {
        case blocked(String)
        case empty
        case loading
        case ready(Status)
        case failed(Problem)
    }

    enum Status: Equatable {
        case notConfigured
        case inSync
        case drifted
        case needsRepair
        case operationInProgress
    }

    enum ScopeChoice: String, CaseIterable, Identifiable {
        case global
        case agents

        var id: Self { self }
    }

    private(set) var loadState: LoadState = .blocked("Preparing the managed library…")
    private(set) var activeSkillID: SkillID?
    private(set) var activeDisplayName = ""
    private(set) var currentBindings: [DistributionBinding] = []
    private(set) var currentTargets: [TargetRow] = []
    private(set) var scopeChoice: ScopeChoice = .global
    private(set) var selectedAgents: Set<SkillPlatform> = []
    private(set) var distributionSlug: DefaultDistributionSlug?
    private(set) var pendingPreview: PendingPreview?
    private(set) var problem: Problem?
    private(set) var successMessage: String?
    private(set) var isRefreshing = false
    private(set) var isPreparingPreview = false
    private(set) var isApplying = false

    private var dependencies: SkillDistributionDependencies?
    private var runtimeReady = false
    private var runtimeBlockMessage = "Preparing the managed library…"
    private var refreshGeneration: UInt64 = 0

    var canPreparePreview: Bool {
        guard runtimeReady, activeSkillID != nil,
              !isRefreshing, !isPreparingPreview, !isApplying else {
            return false
        }
        guard case .ready(let status) = loadState,
              status != .needsRepair,
              status != .operationInProgress else {
            return false
        }
        return scopeChoice == .global || !selectedAgents.isEmpty
    }

    var globalReaders: [SkillPlatform] {
        DistributionTargetCatalog.current.globalReaders
    }

    var globalNonReaders: [SkillPlatform] {
        SkillPlatform.allCases.filter { !$0.readsGlobalDistributionTarget }
    }

    @discardableResult
    func activate(dependencies: SkillDistributionDependencies) -> Bool {
        let needsRefresh = !runtimeReady
        self.dependencies = dependencies
        runtimeReady = true
        if activeSkillID == nil {
            loadState = .empty
        }
        return needsRefresh
    }

    func blockRuntime(message: String) {
        runtimeReady = false
        runtimeBlockMessage = message
        refreshGeneration &+= 1
        pendingPreview = nil
        isRefreshing = false
        isPreparingPreview = false
        loadState = .blocked(message)
    }

    func refresh(skillID: SkillID?, displayName: String?) async {
        await refresh(
            skillID: skillID,
            displayName: displayName,
            whileApplying: false,
            clearFeedback: true
        )
    }

    func refreshCurrent() async {
        guard let activeSkillID else { return }
        await refresh(skillID: activeSkillID, displayName: activeDisplayName)
    }

    private func refresh(
        skillID: SkillID?,
        displayName: String?,
        whileApplying: Bool,
        clearFeedback: Bool
    ) async {
        guard whileApplying || !isApplying else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        pendingPreview = nil
        if clearFeedback {
            problem = nil
            successMessage = nil
        }

        guard let skillID, let displayName else {
            clearSelection()
            loadState = runtimeReady ? .empty : .blocked(runtimeBlockMessage)
            return
        }

        let selectionChanged = activeSkillID != skillID
        activeSkillID = skillID
        activeDisplayName = displayName
        if selectionChanged {
            currentBindings = []
            currentTargets = []
            scopeChoice = .global
            selectedAgents = []
            distributionSlug = nil
            loadState = runtimeReady ? .loading : .blocked(runtimeBlockMessage)
        }

        guard runtimeReady, let dependencies else {
            loadState = .blocked(runtimeBlockMessage)
            return
        }

        isRefreshing = true
        if currentBindings.isEmpty {
            loadState = .loading
        }
        do {
            let bindings = try await dependencies.loadBindings(skillID)
            let reconcile = try await dependencies.reconcile(skillID)
            guard generation == refreshGeneration, activeSkillID == skillID else { return }
            try publish(
                bindings: bindings,
                reconcile: reconcile,
                skillID: skillID,
                displayName: displayName
            )
        } catch {
            guard generation == refreshGeneration, activeSkillID == skillID else { return }
            loadState = .failed(Self.problem(for: error))
        }
        if generation == refreshGeneration {
            isRefreshing = false
        }
    }

    func chooseScope(_ choice: ScopeChoice) {
        guard !isApplying else { return }
        scopeChoice = choice
        pendingPreview = nil
        problem = nil
        successMessage = nil
    }

    func setAgent(_ platform: SkillPlatform, selected: Bool) {
        guard !isApplying else { return }
        if selected {
            selectedAgents.insert(platform)
        } else {
            selectedAgents.remove(platform)
        }
        pendingPreview = nil
        problem = nil
        successMessage = nil
    }

    func preparePreview() async {
        guard scopeChoice == .global || !selectedAgents.isEmpty else {
            problem = .invalidSelection
            return
        }
        guard canPreparePreview,
              let dependencies,
              let skillID = activeSkillID,
              let desiredScope = desiredScope(),
              let distributionSlug else {
            return
        }
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        problem = nil
        successMessage = nil
        let generation = refreshGeneration
        let choice = scopeChoice
        let agents = selectedAgents
        let requiredAdapterCodes = requiredCodes(for: choice, agents: agents)
        do {
            let plan = try await dependencies.plan(skillID, desiredScope, requiredAdapterCodes)
            let canonicalPlan = try plan.canonicalJSONData()
            guard generation == refreshGeneration,
                  activeSkillID == skillID,
                  scopeChoice == choice,
                  selectedAgents == agents,
                  self.distributionSlug == distributionSlug else {
                return
            }
            pendingPreview = PendingPreview(
                skillID: skillID,
                desiredScope: desiredScope,
                requiredAdapterCodes: requiredAdapterCodes,
                plan: plan,
                canonicalPlan: canonicalPlan,
                rows: previewRows(plan: plan, slug: distributionSlug)
            )
        } catch {
            problem = Self.problem(for: error)
        }
    }

    func cancelPreview() {
        guard !isApplying else { return }
        pendingPreview = nil
    }

    func confirmPreview() async {
        guard !isApplying,
              let preview = pendingPreview,
              let dependencies,
              activeSkillID == preview.skillID,
              preview.plan.status != .blocked else {
            return
        }

        isApplying = true
        problem = nil
        successMessage = nil
        defer { isApplying = false }

        do {
            let currentPlan = try await dependencies.plan(
                preview.skillID,
                preview.desiredScope,
                preview.requiredAdapterCodes
            )
            guard try currentPlan.canonicalJSONData() == preview.canonicalPlan else {
                await refreshPreservingFeedback(skillID: preview.skillID)
                problem = .previewExpired
                return
            }

            if currentPlan.status == .noOp {
                await refreshPreservingFeedback(skillID: preview.skillID)
                successMessage = "No distribution changes were needed."
                return
            }

            let operation = try await dependencies.apply(preview.skillID, currentPlan)
            guard operation.phase == .completed, operation.outcome == .applied else {
                await refreshPreservingFeedback(skillID: preview.skillID)
                problem = .operationDidNotComplete
                return
            }
            await refreshPreservingFeedback(skillID: preview.skillID)
            successMessage = "Distribution completed and the current state was refreshed."
        } catch {
            let mapped = Self.problem(for: error)
            await refreshPreservingFeedback(skillID: preview.skillID)
            problem = mapped
        }
    }

    private func publish(
        bindings: [DistributionBinding],
        reconcile: DistributionReconcileResult,
        skillID: SkillID,
        displayName: String
    ) throws {
        guard bindings.allSatisfy({ $0.skillID == skillID && $0.syncMode == .symlink }) else {
            throw SkillDistributionStateError.invalidPersistedBindings
        }
        let slugs = Set(bindings.map(\.distributionSlug))
        guard slugs.count <= 1 else {
            throw SkillDistributionStateError.invalidPersistedBindings
        }

        let hasGlobal = bindings.contains { $0.scope == .global }
        let agents = Set(bindings.compactMap(\.scope.adapter))
        guard !(hasGlobal && !agents.isEmpty),
              hasGlobal ? bindings.count == 1 : agents.count == bindings.count else {
            throw SkillDistributionStateError.invalidPersistedBindings
        }

        let slug = try slugs.first ?? DefaultDistributionSlug(
            candidateFrom: SkillDisplayName(displayName)
        )
        currentBindings = bindings
        distributionSlug = slug
        currentTargets = bindings.compactMap { binding in
            DistributionTargetCatalog.current.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ).map {
                TargetRow(scopeKey: binding.scope.targetScopeKey, locator: $0.canonicalLocator)
            }
        }

        if hasGlobal {
            scopeChoice = .global
            selectedAgents = []
        } else if !agents.isEmpty {
            scopeChoice = .agents
            selectedAgents = agents
        } else {
            scopeChoice = .global
            selectedAgents = []
        }

        let reconciledStatus = Self.status(for: reconcile.status)
        loadState = .ready(
            bindings.isEmpty && reconciledStatus == .inSync
                ? .notConfigured
                : reconciledStatus
        )
    }

    private func desiredScope() -> DistributionDesiredScope? {
        guard let distributionSlug else { return nil }
        switch scopeChoice {
        case .global:
            return .global(distributionSlug)
        case .agents:
            guard !selectedAgents.isEmpty else { return nil }
            return .agents(selectedAgents, distributionSlug)
        }
    }

    private func requiredCodes(
        for choice: ScopeChoice,
        agents: Set<SkillPlatform>
    ) -> Set<String> {
        switch choice {
        case .global:
            Set(globalReaders.map(\.storageKey))
        case .agents:
            Set(agents.map(\.storageKey))
        }
    }

    private func previewRows(
        plan: DistributionPlan,
        slug: DefaultDistributionSlug
    ) -> [PreviewRow] {
        if plan.status == .noOp {
            return currentBindings.compactMap { binding in
                DistributionTargetCatalog.current.entry(for: binding.scope, slug: slug).map {
                    PreviewRow(
                        kind: .noChange,
                        scopeKey: binding.scope.targetScopeKey,
                        locator: $0.canonicalLocator
                    )
                }
            }
        }

        var rows = plan.filesystemActions.map { action in
            PreviewRow(
                kind: action.kind == .removeSymlink ? .remove : .create,
                scopeKey: action.entry.target.scope.targetScopeKey,
                locator: action.entry.canonicalLocator
            )
        }
        if plan.bindingsChanged, plan.filesystemActions.isEmpty {
            rows = plan.bindingReplacement.compactMap { binding in
                DistributionTargetCatalog.current.entry(
                    for: binding.scope,
                    slug: binding.distributionSlug
                ).map {
                    PreviewRow(
                        kind: .binding,
                        scopeKey: binding.scope.targetScopeKey,
                        locator: $0.canonicalLocator
                    )
                }
            }
        }
        return rows
    }

    private func refreshPreservingFeedback(skillID: SkillID) async {
        await refresh(
            skillID: skillID,
            displayName: activeDisplayName,
            whileApplying: true,
            clearFeedback: false
        )
    }

    private func clearSelection() {
        activeSkillID = nil
        activeDisplayName = ""
        currentBindings = []
        currentTargets = []
        selectedAgents = []
        distributionSlug = nil
        pendingPreview = nil
        isRefreshing = false
    }

    private static func status(for status: DistributionReconcileStatus) -> Status {
        switch status {
        case .inSync: .inSync
        case .drifted: .drifted
        case .needsRepair: .needsRepair
        case .operationInProgress: .operationInProgress
        }
    }

    private static func problem(for error: Error) -> Problem {
        if let error = error as? SkillDistributionStateError {
            switch error {
            case .invalidPersistedBindings: return .invalidPersistedBindings
            }
        }
        if let error = error as? DistributionSymlinkExecutorError {
            switch error {
            case .blocked(let conflicts):
                if conflicts.contains(where: { $0.reason == .targetUnavailable }) {
                    return .targetUnavailable
                }
                return .failed("The distribution plan is blocked by a target conflict.")
            case .needsRepair:
                return .needsRepair
            case .operationInProgress:
                return .operationInProgress
            case .conflict:
                return .previewExpired
            }
        }
        if let error = error as? DistributionSymlinkFileSystemError {
            switch error {
            case .unavailable:
                return .targetUnavailable
            case .posix(_, let code) where code == EACCES || code == EPERM:
                return .permissionDenied
            default:
                return .failed(error.localizedDescription)
            }
        }
        if let error = error as? ManagedPathError,
           case .posix(_, let code) = error,
           code == EACCES || code == EPERM {
            return .permissionDenied
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return .permissionDenied
        }
        return .failed(error.localizedDescription)
    }
}

private nonisolated enum SkillDistributionStateError: Error {
    case invalidPersistedBindings
}
