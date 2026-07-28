import Foundation

nonisolated enum DistributionRepairPlanningError: Error, Equatable, Sendable {
    case invalidSelection
    case unsupportedBindingState
    case copyRequiresForkDecision
    case targetOccupied
    case unavailable
}

nonisolated extension DistributionPlanner {
    func repairPlan(
        skillID: SkillID,
        selection: DistributionSelectionReadback,
        intent: DistributionRepairIntent,
        scopeKeys: Set<String>,
        observations: [DistributionTargetEntry: DistributionTargetObservation],
        catalog: DistributionTargetCatalog = .current
    ) throws -> DistributionPlan {
        let bindings = selection.bindings
        if bindings.contains(where: { $0.syncMode == .copy }) {
            throw DistributionRepairPlanningError.copyRequiresForkDecision
        }
        guard !bindings.isEmpty,
              !scopeKeys.isEmpty,
              bindings.allSatisfy({
                  $0.skillID == skillID && $0.syncMode == .symlink
              }),
              Set(bindings.map(\.distributionSlug)).count == 1 else {
            throw DistributionRepairPlanningError.unsupportedBindingState
        }
        do {
            _ = try selection.desiredConfiguration(for: skillID)
        } catch {
            throw DistributionRepairPlanningError.invalidSelection
        }
        let byScope = Dictionary(uniqueKeysWithValues: bindings.map {
            ($0.scope.targetScopeKey, $0)
        })
        guard scopeKeys.isSubset(of: Set(byScope.keys)) else {
            throw DistributionRepairPlanningError.invalidSelection
        }

        let missing = try repairMissingScopes(
            bindings: bindings,
            skillID: skillID,
            observations: observations,
            catalog: catalog
        )
        guard missing == scopeKeys else {
            throw DistributionRepairPlanningError.invalidSelection
        }

        let replacement: [DistributionBindingIntent]
        switch intent {
        case .rebuildMissingSymlink:
            replacement = bindings.map(\.intent)
        case .disableMissingBinding:
            replacement = bindings.compactMap {
                scopeKeys.contains($0.scope.targetScopeKey) ? nil : $0.intent
            }
        }
        let actions = try repairActions(
            skillID: skillID,
            intent: intent,
            scopeKeys: scopeKeys,
            bindingsByScope: byScope,
            catalog: catalog
        )

        return DistributionPlan(
            status: .executable,
            filesystemActions: actions.sorted(by: distributionActionPrecedes),
            bindingsChanged: replacement.count != bindings.count,
            bindingReplacement: replacement.sorted(by: distributionBindingIntentPrecedes),
            configurationChanged: false,
            expectedOldConfigured: selection.isExplicitlyConfigured,
            desiredConfigured: selection.isExplicitlyConfigured,
            conflicts: [],
            repairIntent: intent,
            repairScopeKeys: scopeKeys.sorted(by: utf8Precedes)
        )
    }

    private func repairMissingScopes(
        bindings: [DistributionBinding],
        skillID: SkillID,
        observations: [DistributionTargetEntry: DistributionTargetObservation],
        catalog: DistributionTargetCatalog
    ) throws -> Set<String> {
        var missing = Set<String>()
        for binding in bindings {
            guard let entry = catalog.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ) else {
                throw DistributionRepairPlanningError.unavailable
            }
            switch observations[entry] ?? .unavailable {
            case .missing:
                missing.insert(binding.scope.targetScopeKey)
            case .managed(let owner, let directoryName):
                guard owner == skillID, directoryName == skillID.directoryName else {
                    throw DistributionRepairPlanningError.targetOccupied
                }
            case .copy:
                throw DistributionRepairPlanningError.copyRequiresForkDecision
            case .unknownObject:
                throw DistributionRepairPlanningError.targetOccupied
            case .unavailable:
                throw DistributionRepairPlanningError.unavailable
            }
        }
        return missing
    }

    private func repairActions(
        skillID: SkillID,
        intent: DistributionRepairIntent,
        scopeKeys: Set<String>,
        bindingsByScope: [String: DistributionBinding],
        catalog: DistributionTargetCatalog
    ) throws -> [DistributionFilesystemAction] {
        guard intent == .rebuildMissingSymlink else { return [] }
        return try scopeKeys.map { scopeKey in
            guard let binding = bindingsByScope[scopeKey],
                  let entry = catalog.entry(
                      for: binding.scope,
                      slug: binding.distributionSlug
                  ) else {
                throw DistributionRepairPlanningError.unavailable
            }
            return DistributionFilesystemAction(
                kind: .createSymlink,
                entry: entry,
                ssotLocator: catalog.ssotLocator(for: skillID)
            )
        }
    }
}

nonisolated func distributionRepairScope(
    for scopeKey: String
) -> DistributionBindingScope? {
    if scopeKey == DistributionBindingScope.global.targetScopeKey {
        return .global
    }
    return SkillPlatform.allCases.first {
        scopeKey == DistributionBindingScope.agent($0).targetScopeKey
    }.map(DistributionBindingScope.agent)
}
