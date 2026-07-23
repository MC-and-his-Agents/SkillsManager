import Foundation

nonisolated struct DistributionPlanner {
    func plan(
        skillID: SkillID,
        currentBindings: [DistributionBinding],
        desiredScope: DistributionDesiredScope,
        requiredAdapterCodes: Set<String>,
        observations: [DistributionTargetEntry: DistributionTargetObservation],
        catalog: DistributionTargetCatalog = .current
    ) -> DistributionPlan {
        let current = currentBindings.map(\.intent).sorted(by: distributionBindingIntentPrecedes)
        var conflicts = validateCurrent(current, skillID: skillID)
        let desiredResult = desiredBindings(
            skillID: skillID,
            scope: desiredScope,
            requiredAdapterCodes: requiredAdapterCodes,
            catalog: catalog
        )
        let desired = desiredResult.bindings.sorted(by: distributionBindingIntentPrecedes)
        conflicts.append(contentsOf: desiredResult.conflicts)

        let candidateResult = candidates(current: current, desired: desired, catalog: catalog)
        conflicts.append(contentsOf: candidateResult.conflicts)

        let ssotLocator = catalog.ssotLocator(for: skillID)
        var actions: [DistributionFilesystemAction] = []
        for candidate in candidateResult.candidates {
            let result = evaluate(
                candidate,
                skillID: skillID,
                observation: observations[candidate.entry] ?? .unavailable,
                ssotLocator: ssotLocator
            )
            actions.append(contentsOf: result.actions)
            conflicts.append(contentsOf: result.conflicts)
        }

        if !conflicts.isEmpty {
            return DistributionPlan(
                status: .blocked,
                filesystemActions: [],
                bindingsChanged: false,
                bindingReplacement: [],
                conflicts: Array(Set(conflicts)).sorted(by: distributionConflictPrecedes)
            )
        }

        actions.sort(by: distributionActionPrecedes)
        let bindingsChanged = current != desired
        guard !actions.isEmpty || bindingsChanged else {
            return DistributionPlan(
                status: .noOp,
                filesystemActions: [],
                bindingsChanged: false,
                bindingReplacement: [],
                conflicts: []
            )
        }
        return DistributionPlan(
            status: .executable,
            filesystemActions: actions,
            bindingsChanged: bindingsChanged,
            bindingReplacement: bindingsChanged ? desired : [],
            conflicts: []
        )
    }

    private func validateCurrent(
        _ bindings: [DistributionBindingIntent],
        skillID: SkillID
    ) -> [DistributionPlanConflict] {
        let scopes = bindings.map(\.scope)
        let hasGlobal = scopes.contains(.global)
        let hasAgent = scopes.contains { $0.adapter != nil }
        guard bindings.allSatisfy({ $0.skillID == skillID }),
              Set(scopes).count == scopes.count,
              !(hasGlobal && hasAgent) else {
            return [validationConflict(.invalidDesiredScope)]
        }
        return []
    }

    private func desiredBindings(
        skillID: SkillID,
        scope: DistributionDesiredScope,
        requiredAdapterCodes: Set<String>,
        catalog: DistributionTargetCatalog
    ) -> (bindings: [DistributionBindingIntent], conflicts: [DistributionPlanConflict]) {
        let supportedCodes = Set(SkillPlatform.allCases.map(\.storageKey))
        let unsupportedCodes = requiredAdapterCodes.subtracting(supportedCodes)
        var conflicts = unsupportedCodes.map {
            validationConflict(.unsupportedAdapter, targetScopeKey: "agent:\($0)")
        }

        switch scope {
        case .disabled:
            if !requiredAdapterCodes.isEmpty {
                conflicts.append(validationConflict(.invalidDesiredScope))
            }
            return ([], conflicts)

        case .global(let slug):
            let expected = Set(catalog.globalReaders.map(\.storageKey))
            if requiredAdapterCodes != expected {
                conflicts.append(validationConflict(
                    .globalCoverageMismatch,
                    targetScopeKey: DistributionBindingScope.global.targetScopeKey,
                    slug: slug,
                    targetRank: DistributionBindingScope.global.canonicalRank,
                    locator: catalog.globalTarget.rootLocator
                ))
            }
            return (
                [DistributionBindingIntent(
                    skillID: skillID,
                    scope: .global,
                    distributionSlug: slug
                )],
                conflicts
            )

        case .agents(let adapters, let slug):
            let expected = Set(adapters.map(\.storageKey))
            if adapters.isEmpty || requiredAdapterCodes != expected {
                conflicts.append(validationConflict(.invalidDesiredScope, slug: slug))
            }
            let bindings = adapters.map {
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: .agent($0),
                    distributionSlug: slug
                )
            }
            for binding in bindings where catalog.target(for: binding.scope) == nil {
                conflicts.append(validationConflict(
                    .dedicatedTargetUnavailable,
                    targetScopeKey: binding.scope.targetScopeKey,
                    slug: slug,
                    targetRank: binding.scope.canonicalRank
                ))
            }
            return (bindings, conflicts)
        }
    }

    private func candidates(
        current: [DistributionBindingIntent],
        desired: [DistributionBindingIntent],
        catalog: DistributionTargetCatalog
    ) -> (candidates: [Candidate], conflicts: [DistributionPlanConflict]) {
        var candidates: [DistributionTargetEntry: Candidate] = [:]
        var conflicts: [DistributionPlanConflict] = []
        for binding in current {
            guard let entry = catalog.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ) else {
                conflicts.append(missingTargetConflict(for: binding))
                continue
            }
            candidates[entry, default: Candidate(entry: entry)].current = binding
        }
        for binding in desired {
            guard let entry = catalog.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ) else {
                conflicts.append(missingTargetConflict(for: binding))
                continue
            }
            candidates[entry, default: Candidate(entry: entry)].desired = binding
        }
        return (
            candidates.values.sorted { lhs, rhs in
                if lhs.entry.target.rank != rhs.entry.target.rank {
                    return lhs.entry.target.rank < rhs.entry.target.rank
                }
                if lhs.entry.slugKey != rhs.entry.slugKey {
                    return lhs.entry.slugKey.utf8.lexicographicallyPrecedes(rhs.entry.slugKey.utf8)
                }
                return lhs.entry.canonicalLocator.utf8.lexicographicallyPrecedes(
                    rhs.entry.canonicalLocator.utf8
                )
            },
            conflicts
        )
    }

    private func evaluate(
        _ candidate: Candidate,
        skillID: SkillID,
        observation: DistributionTargetObservation,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        switch (candidate.current != nil, candidate.desired != nil) {
        case (false, true):
            return evaluateAddition(
                candidate.entry,
                skillID: skillID,
                observation: observation,
                ssotLocator: ssotLocator
            )
        case (true, false):
            return evaluateRemoval(
                candidate.entry,
                skillID: skillID,
                observation: observation,
                ssotLocator: ssotLocator
            )
        case (true, true):
            return evaluateRetention(
                candidate.entry,
                skillID: skillID,
                observation: observation
            )
        case (false, false):
            return ([], [])
        }
    }

    private func evaluateAddition(
        _ entry: DistributionTargetEntry,
        skillID: SkillID,
        observation: DistributionTargetObservation,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        switch observation {
        case .missing:
            return ([DistributionFilesystemAction(
                kind: .createSymlink,
                entry: entry,
                ssotLocator: ssotLocator
            )], [])
        case .managed(let owner, let directoryName):
            if owner != skillID {
                return ([], [conflict(.slugOccupied, entry: entry)])
            }
            guard directoryName == skillID.directoryName else {
                return ([], [conflict(.managedTargetMismatch, entry: entry)])
            }
            return ([], [])
        case .unknownObject:
            return ([], [conflict(.unknownObject, entry: entry)])
        case .unavailable:
            return ([], [conflict(.targetUnavailable, entry: entry)])
        }
    }

    private func evaluateRemoval(
        _ entry: DistributionTargetEntry,
        skillID: SkillID,
        observation: DistributionTargetObservation,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        switch observation {
        case .missing:
            return ([], [conflict(.currentBindingMissing, entry: entry)])
        case .managed(let owner, let directoryName):
            guard owner == skillID, directoryName == skillID.directoryName else {
                return ([], [conflict(.managedTargetMismatch, entry: entry)])
            }
            return ([DistributionFilesystemAction(
                kind: .removeSymlink,
                entry: entry,
                ssotLocator: ssotLocator
            )], [])
        case .unknownObject:
            return ([], [conflict(.unknownObject, entry: entry)])
        case .unavailable:
            return ([], [conflict(.targetUnavailable, entry: entry)])
        }
    }

    private func evaluateRetention(
        _ entry: DistributionTargetEntry,
        skillID: SkillID,
        observation: DistributionTargetObservation
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        switch observation {
        case .missing:
            return ([], [conflict(.currentBindingMissing, entry: entry)])
        case .managed(let owner, let directoryName):
            guard owner == skillID, directoryName == skillID.directoryName else {
                return ([], [conflict(.managedTargetMismatch, entry: entry)])
            }
            return ([], [])
        case .unknownObject:
            return ([], [conflict(.unknownObject, entry: entry)])
        case .unavailable:
            return ([], [conflict(.targetUnavailable, entry: entry)])
        }
    }

    private func conflict(
        _ reason: DistributionConflictReason,
        entry: DistributionTargetEntry
    ) -> DistributionPlanConflict {
        DistributionPlanConflict(
            reason: reason,
            targetScopeKey: entry.target.scope.targetScopeKey,
            targetRank: entry.target.rank,
            slugKey: entry.slugKey,
            canonicalLocator: entry.canonicalLocator
        )
    }

    private func missingTargetConflict(
        for binding: DistributionBindingIntent
    ) -> DistributionPlanConflict {
        validationConflict(
            .dedicatedTargetUnavailable,
            targetScopeKey: binding.scope.targetScopeKey,
            slug: binding.distributionSlug,
            targetRank: binding.scope.canonicalRank
        )
    }

    private func validationConflict(
        _ reason: DistributionConflictReason,
        targetScopeKey: String = "",
        slug: DefaultDistributionSlug? = nil,
        targetRank: Int = .max,
        locator: String = ""
    ) -> DistributionPlanConflict {
        DistributionPlanConflict(
            reason: reason,
            targetScopeKey: targetScopeKey,
            targetRank: targetRank,
            slugKey: slug?.collisionKey ?? "",
            canonicalLocator: locator
        )
    }

    private struct Candidate {
        let entry: DistributionTargetEntry
        var current: DistributionBindingIntent?
        var desired: DistributionBindingIntent?

        init(entry: DistributionTargetEntry) {
            self.entry = entry
        }
    }
}
