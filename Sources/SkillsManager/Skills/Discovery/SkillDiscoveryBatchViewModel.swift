import Foundation
import Observation

@MainActor
@Observable final class SkillDiscoveryBatchViewModel {
    private(set) var state: SkillDiscoveryBatchState = .idle
    private(set) var candidates: [SkillDiscoveryBatchCandidate] = []
    private(set) var selectedIDs: Set<SkillDiscoveryBatchCandidateID> = []
    private(set) var selectedActions: [SkillDiscoveryBatchCandidateID: ManagedSkillImportAction] = [:]
    private(set) var preview: SkillDiscoveryBatchPreview?
    private(set) var resultItems: [SkillDiscoveryBatchResultItem] = []
    private(set) var summary = SkillDiscoveryBatchSummary.empty
    private(set) var errorMessage: String?
    private(set) var batchGeneration: UInt64 = 0
    var distributionMode: ManagedInstallDistributionMode = .global
    var selectedAgents: Set<SkillPlatform> = []

    private var dependencies: SkillDiscoveryBatchDependencies?
    private var service: SkillDiscoveryBatchImportService?
    private var currentGeneration: UInt64 = 0

    var availableCandidateCount: Int {
        candidates.count(where: \.isSelectable)
    }

    var selectedCount: Int { selectedIDs.count }

    var isExecuting: Bool { state == .executing }

    var canClose: Bool { state != .executing }

    var canPreview: Bool {
        guard state == .selecting, !selectedIDs.isEmpty, dependencies != nil else {
            return false
        }
        return distributionMode == .global || !selectedAgents.isEmpty
    }

    var canConfirm: Bool {
        state == .ready && preview?.generation == currentGeneration
    }

    func activate(dependencies: SkillDiscoveryBatchDependencies) {
        self.dependencies = dependencies
        service = SkillDiscoveryBatchImportService(dependencies: dependencies)
    }

    func blockRuntime(message: String) {
        dependencies = nil
        service = nil
        guard state != .executing else { return }
        state = .idle
        errorMessage = message
        preview = nil
    }

    func configure(
        items: [SkillDiscoveryViewModel.Item],
        generation: UInt64
    ) {
        guard state != .executing else { return }
        currentGeneration = generation
        batchGeneration = generation
        candidates = SkillDiscoveryBatchCandidate.canonicalCandidates(from: items)
        selectedIDs = Set(candidates.compactMap { candidate in
            candidate.defaultAction == nil ? nil : candidate.id
        })
        selectedActions = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            guard let action = candidate.defaultAction else { return nil }
            return (candidate.id, action)
        })
        preview = nil
        resultItems = []
        summary = .empty
        errorMessage = nil
        state = .selecting
    }

    func invalidate(generation: UInt64) {
        currentGeneration = generation
        batchGeneration = generation
        guard state != .executing, state != .completed else { return }
        guard state != .idle else { return }
        preview = nil
        candidates = []
        selectedIDs = []
        selectedActions = [:]
        errorMessage = String(localized: "Discovery changed. Review the current candidates before importing.", bundle: SkillsManagerLocalizationResources.bundle)
        state = .idle
    }

    func isSelected(_ id: SkillDiscoveryBatchCandidateID) -> Bool {
        selectedIDs.contains(id)
    }

    func action(for id: SkillDiscoveryBatchCandidateID) -> ManagedSkillImportAction? {
        selectedActions[id]
    }

    func toggleSelection(_ id: SkillDiscoveryBatchCandidateID) {
        guard state == .selecting,
              let candidate = candidates.first(where: { $0.id == id }),
              candidate.isSelectable else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            selectedActions.removeValue(forKey: id)
        } else if let action = selectedActions[id] ?? candidate.defaultAction {
            selectedIDs.insert(id)
            selectedActions[id] = action
        }
    }

    func setAction(_ action: ManagedSkillImportAction, for id: SkillDiscoveryBatchCandidateID) {
        guard state == .selecting,
              let candidate = candidates.first(where: { $0.id == id }),
              candidate.allowedActions.contains(action) else { return }
        selectedActions[id] = action
        selectedIDs.insert(id)
    }

    func selectAllSafe() {
        guard state == .selecting else { return }
        selectedIDs = Set(candidates.compactMap { $0.defaultAction == nil ? nil : $0.id })
        selectedActions = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            guard let action = candidate.defaultAction else { return nil }
            return (candidate.id, action)
        })
    }

    func clearSelection() {
        guard state == .selecting else { return }
        selectedIDs.removeAll()
        selectedActions.removeAll()
    }

    func preparePreview() async {
        guard canPreview, let service else { return }
        let generation = batchGeneration
        let selected = candidates
            .filter { selectedIDs.contains($0.id) }
            .sorted { skillDiscoveryObservationPrecedes($0.observation, $1.observation) }
        state = .preparing
        errorMessage = nil
        let scope = requestedScope
        var items: [SkillDiscoveryBatchPreviewItem] = []
        for candidate in selected {
            guard let action = selectedActions[candidate.id] ?? candidate.defaultAction,
                  candidate.allowedActions.contains(action) else {
                continue
            }
            do {
                items.append(try await service.preview(
                    candidate: candidate,
                    action: action,
                    scope: scope
                ))
            } catch {
                items.append(failedPreview(
                    candidate,
                    action: action,
                    message: SkillDiscoveryBatchImportService.message(for: error)
                ))
            }
        }
        guard state == .preparing, batchGeneration == generation,
              currentGeneration == generation else { return }
        preview = SkillDiscoveryBatchPreview(
            generation: generation,
            scope: scope,
            items: items
        )
        state = .ready
    }

    func cancelPreview() {
        guard state != .executing else { return }
        preview = nil
        errorMessage = nil
        if !candidates.isEmpty { state = .selecting }
    }

    func confirm(finalize: @MainActor () async -> Void = {}) async {
        guard state == .ready, let preview, let service else { return }
        guard preview.generation == currentGeneration,
              preview.generation == batchGeneration else {
            errorMessage = String(localized: "Discovery changed. Review the current candidates before importing.", bundle: SkillsManagerLocalizationResources.bundle)
            self.preview = nil
            state = .selecting
            return
        }
        state = .executing
        errorMessage = nil
        resultItems = []
        summary = .empty

        for item in preview.items {
            let result = await execute(item, preview: preview, service: service)
            resultItems.append(result)
            summary = SkillDiscoveryBatchSummary(items: resultItems)
        }

        await finalize()
        state = .completed
    }

    func reset() {
        guard state != .executing else { return }
        state = .idle
        candidates = []
        selectedIDs = []
        selectedActions = [:]
        preview = nil
        resultItems = []
        summary = .empty
        errorMessage = nil
    }

    private var requestedScope: ManagedLocalImportScope {
        switch distributionMode {
        case .global:
            .global
        case .agents:
            .agents(selectedAgents)
        }
    }

    private func failedPreview(
        _ candidate: SkillDiscoveryBatchCandidate,
        action: ManagedSkillImportAction,
        message: String
    ) -> SkillDiscoveryBatchPreviewItem {
        SkillDiscoveryBatchPreviewItem(
            id: candidate.id,
            action: action,
            token: nil,
            displayName: candidate.observation.displayName,
            skillID: candidate.observation.matchedSkillID,
            distributionSlug: nil,
            sourceURLs: candidate.aliases.map(\.url),
            reason: message,
            plan: nil,
            canonicalPlan: nil
        )
    }

    private func execute(
        _ item: SkillDiscoveryBatchPreviewItem,
        preview: SkillDiscoveryBatchPreview,
        service: SkillDiscoveryBatchImportService
    ) async -> SkillDiscoveryBatchResultItem {
        guard let token = item.token else {
            return SkillDiscoveryBatchResultItem(
                id: item.id,
                action: item.action,
                displayName: item.displayName,
                sourceURLs: item.sourceURLs,
                management: .skipped(item.reason ?? String(localized: "This item was skipped.", bundle: SkillsManagerLocalizationResources.bundle)),
                distribution: .notApplicable(String(localized: "No managed write was attempted.", bundle: SkillsManagerLocalizationResources.bundle))
            )
        }
        do {
            let managed = try await service.execute(token)
            switch managed.disposition {
            case .created:
                let distribution = await applyDistribution(
                    item,
                    skillID: managed.skill.skillID,
                    scope: preview.scope,
                    service: service
                )
                return SkillDiscoveryBatchResultItem(
                    id: item.id,
                    action: item.action,
                    displayName: item.displayName,
                    sourceURLs: item.sourceURLs,
                    management: .created,
                    distribution: distribution
                )
            case .claimed:
                return SkillDiscoveryBatchResultItem(
                    id: item.id,
                    action: item.action,
                    displayName: item.displayName,
                    sourceURLs: item.sourceURLs,
                    management: .claimed,
                    distribution: .notApplicable(String(localized: "Existing Agent bindings were preserved.", bundle: SkillsManagerLocalizationResources.bundle))
                )
            case .alreadyManaged:
                return SkillDiscoveryBatchResultItem(
                    id: item.id,
                    action: item.action,
                    displayName: item.displayName,
                    sourceURLs: item.sourceURLs,
                    management: .alreadyManaged,
                    distribution: .notApplicable(String(localized: "Existing Agent bindings were preserved.", bundle: SkillsManagerLocalizationResources.bundle))
                )
            }
        } catch {
            return SkillDiscoveryBatchResultItem(
                id: item.id,
                action: item.action,
                displayName: item.displayName,
                sourceURLs: item.sourceURLs,
                management: .failed(SkillDiscoveryBatchImportService.message(for: error)),
                distribution: .notApplicable(String(localized: "No managed Skill was confirmed.", bundle: SkillsManagerLocalizationResources.bundle))
            )
        }
    }

    private func applyDistribution(
        _ item: SkillDiscoveryBatchPreviewItem,
        skillID: SkillID,
        scope: ManagedLocalImportScope,
        service: SkillDiscoveryBatchImportService
    ) async -> SkillDiscoveryBatchDistributionResult {
        guard item.plan != nil else {
            return .indeterminate(item.reason ?? String(localized: "Distribution preview was unavailable.", bundle: SkillsManagerLocalizationResources.bundle))
        }
        guard let slug = item.distributionSlug else {
            return .indeterminate(String(localized: "Distribution slug was unavailable.", bundle: SkillsManagerLocalizationResources.bundle))
        }
        let currentPlan: DistributionPlan
        do {
            currentPlan = try await service.replan(
                skillID: skillID,
                slug: slug,
                scope: scope
            )
            guard let canonicalPlan = item.canonicalPlan,
                  try currentPlan.canonicalJSONData() == canonicalPlan else {
                return .indeterminate(String(localized: "Distribution changed after preview.", bundle: SkillsManagerLocalizationResources.bundle))
            }
        } catch {
            return .indeterminate(SkillDiscoveryBatchImportService.message(for: error))
        }
        switch currentPlan.status {
        case .noOp:
            return .noChanges
        case .blocked:
            return .managedUndistributed
        case .executable:
            do {
                let operation = try await service.apply(skillID: skillID, plan: currentPlan)
                guard operation.phase == .completed,
                      operation.outcome == .applied else {
                    return .indeterminate(String(localized: "Distribution did not complete.", bundle: SkillsManagerLocalizationResources.bundle))
                }
                return .distributed
            } catch {
                return .indeterminate(SkillDiscoveryBatchImportService.message(for: error))
            }
        }
    }
}
