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

    private(set) var loadState: LoadState = .blocked("Preparing the managed library…")
    private(set) var activeSkillID: SkillID?
    private(set) var activeDisplayName = ""
    private(set) var currentBindings: [DistributionBinding] = []
    private(set) var currentTargets: [TargetRow] = []
    private(set) var currentEnabledAgents: Set<SkillPlatform> = []
    private(set) var selectedAgents: Set<SkillPlatform> = []
    private(set) var isExplicitlyConfigured = false
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
        return true
    }
    var globalReaders: [SkillPlatform] {
        DistributionTargetCatalog.current.globalReaders
    }

    var hasUnappliedDraft: Bool {
        selectedAgents != currentEnabledAgents
    }

    var willConvertGlobalToDedicated: Bool {
        currentBindings.contains { $0.scope == .global }
            && !selectedAgents.isEmpty
            && selectedAgents != Set(globalReaders)
    }

    var draftUsesGlobalTarget: Bool {
        selectedAgents == Set(globalReaders)
    }

    var agentRows: [AgentRow] {
        guard let distributionSlug else { return [] }
        let usesGlobal = selectedAgents == Set(globalReaders)
        return SkillPlatform.allCases.compactMap { platform in
            let scope: DistributionBindingScope = usesGlobal && platform.readsGlobalDistributionTarget
                ? .global
                : .agent(platform)
            return DistributionTargetCatalog.current.entry(
                for: scope,
                slug: distributionSlug
            ).map {
                AgentRow(
                    platform: platform,
                    locator: $0.canonicalLocator,
                    readsGlobalTarget: platform.readsGlobalDistributionTarget,
                    isCurrentlyEnabled: currentEnabledAgents.contains(platform),
                    isSelected: selectedAgents.contains(platform)
                )
            }
        }
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
        clearFeedback: Bool
    ) async {
        let previousSkillID = activeSkillID
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if !isApplying || skillID != previousSkillID {
            pendingPreview = nil
        }
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
            currentEnabledAgents = []
            selectedAgents = []
            isExplicitlyConfigured = false
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
            let selection = try await dependencies.loadSelection(skillID)
            let reconcile = try await dependencies.reconcile(skillID)
            guard generation == refreshGeneration, activeSkillID == skillID else { return }
            try publish(
                selection: selection,
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

    func removeFromAllAgents() {
        guard !isApplying else { return }
        selectedAgents = []
        pendingPreview = nil
        problem = nil
        successMessage = nil
    }

    func preparePreview() async {
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
        let agents = selectedAgents
        let requiredAdapterCodes = requiredCodes(agents)
        do {
            let plan = try await dependencies.plan(skillID, desiredScope, requiredAdapterCodes)
            let canonicalPlan = try plan.canonicalJSONData()
            guard generation == refreshGeneration,
                  activeSkillID == skillID,
                  selectedAgents == agents,
                  self.distributionSlug == distributionSlug else {
                return
            }
            pendingPreview = PendingPreview(
                generation: generation,
                skillID: skillID,
                desiredScope: desiredScope,
                requiredAdapterCodes: requiredAdapterCodes,
                plan: plan,
                canonicalPlan: canonicalPlan,
                rows: previewRows(plan: plan, slug: distributionSlug)
            )
        } catch {
            guard generation == refreshGeneration,
                  activeSkillID == skillID,
                  selectedAgents == agents,
                  self.distributionSlug == distributionSlug else {
                return
            }
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
              previewIsCurrent(preview),
              preview.plan.status != .blocked else {
            return
        }

        isApplying = true
        problem = nil
        successMessage = nil
        var didStartApply = false
        defer { isApplying = false }

        do {
            let currentPlan = try await dependencies.plan(
                preview.skillID,
                preview.desiredScope,
                preview.requiredAdapterCodes
            )
            guard previewIsCurrent(preview) else {
                if activeSkillID == preview.skillID {
                    pendingPreview = nil
                    problem = .previewExpired
                }
                return
            }
            guard try currentPlan.canonicalJSONData() == preview.canonicalPlan else {
                pendingPreview = nil
                await refreshPreservingFeedback(skillID: preview.skillID)
                problem = .previewExpired
                return
            }

            if currentPlan.status == .noOp {
                pendingPreview = nil
                await refreshPreservingFeedback(skillID: preview.skillID)
                successMessage = "No distribution changes were needed."
                return
            }

            didStartApply = true
            let operation = try await dependencies.apply(preview.skillID, currentPlan)
            guard activeSkillID == preview.skillID else { return }
            pendingPreview = nil
            guard operation.phase == .completed, operation.outcome == .applied else {
                await refreshPreservingFeedback(skillID: preview.skillID)
                problem = .operationDidNotComplete
                return
            }
            await refreshPreservingFeedback(skillID: preview.skillID)
            successMessage = "Distribution completed and the current state was refreshed."
        } catch {
            if !didStartApply, !previewIsCurrent(preview) {
                if activeSkillID == preview.skillID {
                    pendingPreview = nil
                    problem = .previewExpired
                }
                return
            }
            guard activeSkillID == preview.skillID else { return }
            pendingPreview = nil
            let mapped = Self.problem(for: error)
            await refreshPreservingFeedback(skillID: preview.skillID)
            problem = mapped
        }
    }

    private func publish(
        selection: DistributionSelectionReadback,
        reconcile: DistributionReconcileResult,
        skillID: SkillID,
        displayName: String
    ) throws {
        let bindings = selection.bindings
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
        isExplicitlyConfigured = selection.isExplicitlyConfigured
        distributionSlug = slug
        currentTargets = bindings.compactMap { binding in
            DistributionTargetCatalog.current.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ).map {
                TargetRow(scopeKey: binding.scope.targetScopeKey, locator: $0.canonicalLocator)
            }
        }

        currentEnabledAgents = hasGlobal ? Set(globalReaders) : agents
        selectedAgents = bindings.isEmpty && !selection.isExplicitlyConfigured
            ? Set(globalReaders)
            : currentEnabledAgents

        let reconciledStatus = Self.status(for: reconcile.status)
        loadState = .ready(
            bindings.isEmpty && !selection.isExplicitlyConfigured
                && reconciledStatus == .inSync
                ? .notConfigured
                : reconciledStatus
        )
    }

    private func desiredScope() -> DistributionDesiredScope? {
        guard let distributionSlug else { return nil }
        if selectedAgents.isEmpty { return .disabled }
        if selectedAgents == Set(globalReaders) { return .global(distributionSlug) }
        return .agents(selectedAgents, distributionSlug)
    }

    private func requiredCodes(_ agents: Set<SkillPlatform>) -> Set<String> {
        Set(agents.map(\.storageKey))
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
        let actionScopeKeys = Set(
            plan.filesystemActions.map(\.entry.target.scope.targetScopeKey)
        )
        rows.append(contentsOf: plan.bindingReplacement.compactMap { intent in
            guard !actionScopeKeys.contains(intent.scope.targetScopeKey) else {
                return nil
            }
            return DistributionTargetCatalog.current.entry(
                for: intent.scope,
                slug: intent.distributionSlug
            ).map {
                PreviewRow(
                    kind: currentBindings.contains(where: { $0.intent == intent })
                        ? .noChange
                        : .binding,
                    scopeKey: intent.scope.targetScopeKey,
                    locator: $0.canonicalLocator
                )
            }
        })
        if rows.isEmpty, plan.configurationChanged {
            rows.append(PreviewRow(
                kind: .configuration,
                scopeKey: "configuration",
                locator: "Skills Manager database"
            ))
        }
        return rows
    }

    private func refreshPreservingFeedback(skillID: SkillID) async {
        let draft = selectedAgents
        await refresh(
            skillID: skillID,
            displayName: activeDisplayName,
            clearFeedback: false
        )
        if activeSkillID == skillID, case .ready = loadState {
            selectedAgents = draft
        }
    }

    private func previewIsCurrent(_ preview: PendingPreview) -> Bool {
        preview.generation == refreshGeneration
            && activeSkillID == preview.skillID
            && desiredScopeMatches(preview.desiredScope)
            && requiredCodes(selectedAgents) == preview.requiredAdapterCodes
    }

    private func desiredScopeMatches(_ expected: DistributionDesiredScope) -> Bool {
        guard let current = desiredScope() else { return false }
        return switch (current, expected) {
        case (.disabled, .disabled):
            true
        case (.global(let lhs), .global(let rhs)):
            lhs == rhs
        case (.agents(let lhsAgents, let lhsSlug), .agents(let rhsAgents, let rhsSlug)):
            lhsAgents == rhsAgents && lhsSlug == rhsSlug
        default:
            false
        }
    }

    private func clearSelection() {
        activeSkillID = nil
        activeDisplayName = ""
        currentBindings = []
        currentTargets = []
        currentEnabledAgents = []
        selectedAgents = []
        isExplicitlyConfigured = false
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
}
