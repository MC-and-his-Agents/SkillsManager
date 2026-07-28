import Foundation
import Observation
@MainActor
@Observable final class SkillDistributionViewModel {
    private(set) var loadState: LoadState = .blocked("Preparing the managed library…")
    private(set) var activeSkillID: SkillID?
    private(set) var activeDisplayName = ""
    private(set) var currentBindings: [DistributionBinding] = []
    private(set) var currentTargets: [TargetRow] = []
    private(set) var currentEnabledAgents: Set<SkillPlatform> = []
    private(set) var selectedAgents: Set<SkillPlatform> = []
    private(set) var currentSyncMode: DistributionSyncMode = .symlink
    private(set) var selectedSyncMode: DistributionSyncMode = .symlink
    private(set) var isExplicitlyConfigured = false
    private(set) var distributionSlug: DefaultDistributionSlug?
    private(set) var forkLineage: ForkLineageRow?
    private(set) var pendingPreview: PendingPreview?
    private(set) var problem: Problem?
    private(set) var successMessage: String?
    private(set) var requestedForkChildSkillID: SkillID?
    private(set) var publishedForkSelectionGeneration: UInt64 = 0
    private(set) var isRefreshing = false
    private(set) var isPreparingPreview = false
    private(set) var isApplying = false

    private var dependencies: SkillDistributionDependencies?
    private var runtimeReady = false
    private var runtimeBlockMessage = "Preparing the managed library…"
    private(set) var refreshGeneration: UInt64 = 0

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
            let lineage = try await dependencies.loadForkLineage(skillID)
            guard generation == refreshGeneration, activeSkillID == skillID else { return }
            try publish(
                selection: selection,
                reconcile: reconcile,
                lineage: lineage,
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

    func setSyncMode(_ mode: DistributionSyncMode) {
        guard !isApplying else { return }
        selectedSyncMode = mode
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
              let desiredConfiguration = desiredConfiguration(),
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
            let plan = try await dependencies.plan(
                skillID,
                desiredConfiguration,
                requiredAdapterCodes
            )
            let canonicalPlan = try plan.canonicalJSONData()
            guard generation == refreshGeneration,
                  activeSkillID == skillID,
                  selectedAgents == agents,
                  selectedSyncMode == desiredConfiguration.syncMode,
                  self.distributionSlug == distributionSlug else {
                return
            }
            let driftDecisions = try await eligibleDriftDecisions(
                plan: plan,
                skillID: skillID,
                dependencies: dependencies
            )
            guard generation == refreshGeneration,
                  activeSkillID == skillID,
                  selectedAgents == agents,
                  selectedSyncMode == desiredConfiguration.syncMode,
                  self.distributionSlug == distributionSlug else {
                return
            }
            pendingPreview = PendingPreview(
                generation: generation,
                skillID: skillID,
                desiredConfiguration: desiredConfiguration,
                requiredAdapterCodes: requiredAdapterCodes,
                plan: plan,
                canonicalPlan: canonicalPlan,
                rows: previewRows(plan: plan, slug: distributionSlug),
                driftDecisions: driftDecisions
            )
        } catch {
            guard generation == refreshGeneration,
                  activeSkillID == skillID,
                  selectedAgents == agents,
                  selectedSyncMode == desiredConfiguration.syncMode,
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
                preview.desiredConfiguration,
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

    func discardLocalChanges(_ decision: DriftDecision) async {
        guard beginDecision(decision), let dependencies else { return }
        defer { isApplying = false }
        do {
            let operation = try await dependencies.discardCopyDrift(decision.preview)
            guard activeSkillID == decision.preview.forkPreview.parentSkillID else { return }
            pendingPreview = nil
            guard operation.phase == .completed, operation.outcome == .applied else {
                await refreshPreservingFeedback(skillID: decision.preview.forkPreview.parentSkillID)
                problem = .operationDidNotComplete
                return
            }
            await refreshPreservingFeedback(skillID: decision.preview.forkPreview.parentSkillID)
            successMessage = "Local Copy changes were discarded and restored from the managed Skill."
        } catch {
            await finishDecisionFailure(error, decision: decision)
        }
    }

    func keepAsFork(_ decision: DriftDecision) async {
        guard beginDecision(decision), let dependencies else { return }
        defer { isApplying = false }
        do {
            let result = try await dependencies.createCopyFork(decision.preview)
            guard activeSkillID == result.parentSkillID else { return }
            pendingPreview = nil
            await refreshPreservingFeedback(skillID: result.parentSkillID)
            successMessage = "An independent local Fork was created."
            requestedForkChildSkillID = result.childSkillID
            publishedForkSelectionGeneration &+= 1
        } catch {
            await finishDecisionFailure(error, decision: decision)
        }
    }

    func reportForkSelectionFailure(_ childSkillID: SkillID) {
        guard requestedForkChildSkillID == childSkillID else { return }
        problem = .forkCreatedButNotLocated
    }

    func acknowledgeForkSelection(_ childSkillID: SkillID) {
        guard requestedForkChildSkillID == childSkillID else { return }
        requestedForkChildSkillID = nil
    }

    private func beginDecision(_ decision: DriftDecision) -> Bool {
        guard !isApplying,
              let preview = pendingPreview,
              previewIsCurrent(preview),
              preview.driftDecisions.contains(where: { $0.id == decision.id }) else {
            return false
        }
        isApplying = true
        problem = nil
        successMessage = nil
        return true
    }

    private func finishDecisionFailure(
        _ error: Error,
        decision: DriftDecision
    ) async {
        guard activeSkillID == decision.preview.forkPreview.parentSkillID else {
            return
        }
        pendingPreview = nil
        let mapped = Self.problem(for: error)
        await refreshPreservingFeedback(
            skillID: decision.preview.forkPreview.parentSkillID
        )
        problem = mapped
    }

    private func publish(
        selection: DistributionSelectionReadback,
        reconcile: DistributionReconcileResult,
        lineage: SkillForkLineageReadback?,
        skillID: SkillID,
        displayName: String
    ) throws {
        let bindings = selection.bindings
        guard bindings.allSatisfy({ $0.skillID == skillID }) else {
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
        let configuration = try selection.desiredConfiguration(for: skillID)
        currentSyncMode = configuration.syncMode
        selectedSyncMode = configuration.syncMode
        isExplicitlyConfigured = selection.isExplicitlyConfigured
        distributionSlug = slug
        currentTargets = bindings.compactMap { binding in
            DistributionTargetCatalog.current.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ).map {
                TargetRow(
                    scopeKey: binding.scope.targetScopeKey,
                    locator: $0.canonicalLocator,
                    syncMode: binding.syncMode
                )
            }
        }
        forkLineage = lineage.map(ForkLineageRow.init)

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

    private func refreshPreservingFeedback(skillID: SkillID) async {
        let draft = selectedAgents
        let mode = selectedSyncMode
        await refresh(
            skillID: skillID,
            displayName: activeDisplayName,
            clearFeedback: false
        )
        if activeSkillID == skillID, case .ready = loadState {
            selectedAgents = draft
            selectedSyncMode = mode
        }
    }

    private func clearSelection() {
        activeSkillID = nil
        activeDisplayName = ""
        currentBindings = []
        currentTargets = []
        currentEnabledAgents = []
        selectedAgents = []
        currentSyncMode = .symlink
        selectedSyncMode = .symlink
        isExplicitlyConfigured = false
        distributionSlug = nil
        forkLineage = nil
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
