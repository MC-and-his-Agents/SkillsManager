import Foundation

nonisolated struct DistributionPlanner {
    func plan(
        skillID: SkillID,
        currentBindings: [DistributionBinding],
        currentConfigured: Bool = true,
        desiredScope: DistributionDesiredScope,
        desiredConfigured: Bool = true,
        requiredAdapterCodes: Set<String>,
        observations: [DistributionTargetEntry: DistributionTargetObservation],
        catalog: DistributionTargetCatalog = .current
    ) -> DistributionPlan {
        plan(
            skillID: skillID,
            currentBindings: currentBindings,
            currentConfigured: currentConfigured,
            desiredConfiguration: DistributionDesiredConfiguration(
                scope: desiredScope,
                syncMode: .symlink
            ),
            desiredConfigured: desiredConfigured,
            requiredAdapterCodes: requiredAdapterCodes,
            observations: observations,
            catalog: catalog
        )
    }

    func plan(
        skillID: SkillID,
        currentBindings: [DistributionBinding],
        currentConfigured: Bool = true,
        desiredConfiguration: DistributionDesiredConfiguration,
        desiredConfigured: Bool = true,
        requiredAdapterCodes: Set<String>,
        observations: [DistributionTargetEntry: DistributionTargetObservation],
        catalog: DistributionTargetCatalog = .current
    ) -> DistributionPlan {
        let current = currentBindings.map(\.intent).sorted(by: distributionBindingIntentPrecedes)
        var conflicts = validateCurrent(current, skillID: skillID)
        let desiredResult = desiredBindings(
            skillID: skillID,
            configuration: desiredConfiguration,
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
                configurationChanged: currentConfigured != desiredConfigured,
                expectedOldConfigured: currentConfigured,
                desiredConfigured: desiredConfigured,
                conflicts: Array(Set(conflicts)).sorted(by: distributionConflictPrecedes)
            )
        }

        actions.sort(by: distributionActionPrecedes)
        let bindingsChanged = current != desired
        let configurationChanged = currentConfigured != desiredConfigured
        guard !actions.isEmpty || bindingsChanged || configurationChanged else {
            return DistributionPlan(
                status: .noOp,
                filesystemActions: [],
                bindingsChanged: false,
                bindingReplacement: [],
                configurationChanged: false,
                expectedOldConfigured: currentConfigured,
                desiredConfigured: desiredConfigured,
                conflicts: []
            )
        }
        return DistributionPlan(
            status: .executable,
            filesystemActions: actions,
            bindingsChanged: bindingsChanged,
            bindingReplacement: (!actions.isEmpty || bindingsChanged) ? desired : [],
            configurationChanged: configurationChanged,
            expectedOldConfigured: currentConfigured,
            desiredConfigured: desiredConfigured,
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
              Set(bindings.map(\.distributionSlug)).count <= 1,
              Set(bindings.map(\.syncMode)).count <= 1,
              !(hasGlobal && hasAgent) else {
            return [validationConflict(.invalidDesiredScope)]
        }
        return []
    }

    private func desiredBindings(
        skillID: SkillID,
        configuration: DistributionDesiredConfiguration,
        requiredAdapterCodes: Set<String>,
        catalog: DistributionTargetCatalog
    ) -> (bindings: [DistributionBindingIntent], conflicts: [DistributionPlanConflict]) {
        let supportedCodes = Set(SkillPlatform.allCases.map(\.storageKey))
        let unsupportedCodes = requiredAdapterCodes.subtracting(supportedCodes)
        var conflicts = unsupportedCodes.map {
            validationConflict(.unsupportedAdapter, targetScopeKey: "agent:\($0)")
        }

        switch configuration.scope {
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
                    distributionSlug: slug,
                    syncMode: configuration.syncMode
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
                    distributionSlug: slug,
                    syncMode: configuration.syncMode
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
            guard let desired = candidate.desired else { return ([], []) }
            return evaluateAddition(
                candidate.entry,
                mode: desired.syncMode,
                skillID: skillID,
                observation: observation,
                ssotLocator: ssotLocator
            )
        case (true, false):
            guard let current = candidate.current else { return ([], []) }
            return evaluateRemoval(
                candidate.entry,
                mode: current.syncMode,
                skillID: skillID,
                observation: observation,
                ssotLocator: ssotLocator
            )
        case (true, true):
            guard let current = candidate.current, let desired = candidate.desired else {
                return ([], [])
            }
            if current.syncMode != desired.syncMode {
                return evaluateModeTransition(
                    candidate.entry,
                    currentMode: current.syncMode,
                    desiredMode: desired.syncMode,
                    skillID: skillID,
                    observation: observation,
                    ssotLocator: ssotLocator
                )
            }
            return evaluateRetention(
                candidate.entry,
                mode: current.syncMode,
                skillID: skillID,
                observation: observation,
                ssotLocator: ssotLocator
            )
        case (false, false):
            return ([], [])
        }
    }

    private func evaluateAddition(
        _ entry: DistributionTargetEntry,
        mode: DistributionSyncMode,
        skillID: SkillID,
        observation: DistributionTargetObservation,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        switch observation {
        case .missing:
            return ([DistributionFilesystemAction(
                kind: mode == .symlink ? .createSymlink : .createCopy,
                entry: entry,
                ssotLocator: ssotLocator
            )], [])
        case .managed(let owner, let directoryName):
            guard mode == .symlink else {
                return ([], [conflict(.managedTargetMismatch, entry: entry)])
            }
            if owner != skillID {
                return ([], [conflict(.slugOccupied, entry: entry)])
            }
            guard directoryName == skillID.directoryName else {
                return ([], [conflict(.managedTargetMismatch, entry: entry)])
            }
            return ([], [])
        case .copy(let copy):
            return ([], [copyConflict(.copyBaselineInvalid, entry: entry, copy: copy)])
        case .unknownObject:
            return ([], [conflict(.unknownObject, entry: entry)])
        case .unavailable:
            return ([], [conflict(.targetUnavailable, entry: entry)])
        }
    }

    private func evaluateRemoval(
        _ entry: DistributionTargetEntry,
        mode: DistributionSyncMode,
        skillID: SkillID,
        observation: DistributionTargetObservation,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        if mode == .copy {
            return evaluateCopyMutation(
                entry,
                observation: observation,
                safeAction: .removeCopy,
                ssotLocator: ssotLocator
            )
        }
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
        case .copy:
            return ([], [conflict(.managedTargetMismatch, entry: entry)])
        case .unknownObject:
            return ([], [conflict(.unknownObject, entry: entry)])
        case .unavailable:
            return ([], [conflict(.targetUnavailable, entry: entry)])
        }
    }

    private func evaluateRetention(
        _ entry: DistributionTargetEntry,
        mode: DistributionSyncMode,
        skillID: SkillID,
        observation: DistributionTargetObservation,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        if mode == .copy {
            return evaluateCopyRetention(
                entry,
                observation: observation,
                ssotLocator: ssotLocator
            )
        }
        switch observation {
        case .missing:
            return ([], [conflict(.currentBindingMissing, entry: entry)])
        case .managed(let owner, let directoryName):
            guard owner == skillID, directoryName == skillID.directoryName else {
                return ([], [conflict(.managedTargetMismatch, entry: entry)])
            }
            return ([], [])
        case .copy:
            return ([], [conflict(.managedTargetMismatch, entry: entry)])
        case .unknownObject:
            return ([], [conflict(.unknownObject, entry: entry)])
        case .unavailable:
            return ([], [conflict(.targetUnavailable, entry: entry)])
        }
    }

    private func evaluateModeTransition(
        _ entry: DistributionTargetEntry,
        currentMode: DistributionSyncMode,
        desiredMode: DistributionSyncMode,
        skillID: SkillID,
        observation: DistributionTargetObservation,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        switch (currentMode, desiredMode) {
        case (.symlink, .copy):
            guard case .managed(let owner, let directoryName) = observation,
                  owner == skillID, directoryName == skillID.directoryName else {
                return ([], [conflict(.managedTargetMismatch, entry: entry)])
            }
            return ([DistributionFilesystemAction(
                kind: .replaceSymlinkWithCopy,
                entry: entry,
                ssotLocator: ssotLocator
            )], [])
        case (.copy, .symlink):
            return evaluateCopyMutation(
                entry,
                observation: observation,
                safeAction: .replaceCopyWithSymlink,
                ssotLocator: ssotLocator
            )
        default:
            return ([], [conflict(.invalidDesiredScope, entry: entry)])
        }
    }

    private func evaluateCopyRetention(
        _ entry: DistributionTargetEntry,
        observation: DistributionTargetObservation,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        guard case .copy(let copy) = observation else {
            return ([], [copyStateConflict(entry: entry, observation: observation)])
        }
        switch copy.state {
        case .inSync:
            return ([], [])
        case .sourceChanged:
            return ([DistributionFilesystemAction(
                kind: .refreshCopy,
                entry: entry,
                ssotLocator: ssotLocator
            )], [])
        default:
            return ([], [copyConflict(reason(for: copy.state), entry: entry, copy: copy)])
        }
    }

    private func evaluateCopyMutation(
        _ entry: DistributionTargetEntry,
        observation: DistributionTargetObservation,
        safeAction: DistributionFilesystemActionKind,
        ssotLocator: String
    ) -> (actions: [DistributionFilesystemAction], conflicts: [DistributionPlanConflict]) {
        guard case .copy(let copy) = observation else {
            return ([], [copyStateConflict(entry: entry, observation: observation)])
        }
        switch copy.state {
        case .inSync, .sourceChanged:
            return ([DistributionFilesystemAction(
                kind: safeAction,
                entry: entry,
                ssotLocator: ssotLocator
            )], [])
        default:
            return ([], [copyConflict(reason(for: copy.state), entry: entry, copy: copy)])
        }
    }

    private func copyStateConflict(
        entry: DistributionTargetEntry,
        observation: DistributionTargetObservation
    ) -> DistributionPlanConflict {
        switch observation {
        case .missing:
            conflict(.copyTargetMissing, entry: entry)
        case .unavailable:
            conflict(.targetUnavailable, entry: entry)
        default:
            conflict(.copyBaselineInvalid, entry: entry)
        }
    }

    private func reason(
        for state: DistributionCopyObservationState
    ) -> DistributionConflictReason {
        switch state {
        case .inSync, .sourceChanged: .copyBaselineInvalid
        case .contentDrift: .copyContentDrift
        case .physicalDrift: .copyPhysicalDrift
        case .rootReplaced: .copyRootReplaced
        case .targetReplaced: .copyTargetReplaced
        case .targetMissing: .copyTargetMissing
        case .baselineInvalid: .copyBaselineInvalid
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

    private func copyConflict(
        _ reason: DistributionConflictReason,
        entry: DistributionTargetEntry,
        copy: DistributionCopyObservation
    ) -> DistributionPlanConflict {
        DistributionPlanConflict(
            reason: reason,
            targetScopeKey: entry.target.scope.targetScopeKey,
            targetRank: entry.target.rank,
            slugKey: entry.slugKey,
            canonicalLocator: entry.canonicalLocator,
            copyEvidence: copy.evidence
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
