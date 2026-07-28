import Foundation

nonisolated extension DistributionCopyExecutor {
    func desiredBindingIntents(
        skillID: SkillID,
        configuration: DistributionDesiredConfiguration
    ) -> [DistributionBindingIntent] {
        guard let slug = configuration.scope.distributionSlug else { return [] }
        let scopes: [DistributionBindingScope]
        switch configuration.scope {
        case .disabled:
            scopes = []
        case .global:
            scopes = [.global]
        case .agents(let adapters, _):
            scopes = adapters.map(DistributionBindingScope.agent)
        }
        return scopes.map {
            DistributionBindingIntent(
                skillID: skillID,
                scope: $0,
                distributionSlug: slug,
                syncMode: configuration.syncMode
            )
        }
    }

    func observeCurrent(
        _ entry: DistributionTargetEntry,
        binding: DistributionBinding,
        source: DistributionCopySource,
        linkOwnership: [DistributionLinkOwnership]
    ) throws -> DistributionTargetObservation {
        if binding.syncMode == .symlink {
            guard let ownership = linkOwnership.first(where: {
                $0.targetScopeKey == binding.scope.targetScopeKey
            }) else {
                return .unknownObject
            }
            switch try fileSystem.observe(entry) {
            case .missing:
                return .missing
            case .unavailable:
                return .unavailable
            case .unknown:
                return .unknownObject
            case .symlink(let root, let target, let absoluteTarget):
                guard root == ownership.rootIdentity,
                      target == ownership.entryIdentity,
                      absoluteTarget == ownership.absoluteLinkTarget else {
                    return .unknownObject
                }
                return .managed(
                    skillID: binding.skillID,
                    ssotDirectoryName: binding.skillID.directoryName
                )
            }
        }

        guard let baseline = binding.copyBaseline else {
            return copyObservation(
                .baselineInvalid,
                skillID: binding.skillID,
                baseline: nil,
                observed: nil
            )
        }
        switch try fileSystem.observeCopy(entry) {
        case .missing(let root):
            return copyObservation(
                .targetMissing,
                skillID: binding.skillID,
                baseline: baseline,
                observedRoot: root
            )
        case .unavailable:
            return .unavailable
        case .invalid(let root, let target), .unknown(let root, let target):
            return copyObservation(
                .targetReplaced,
                skillID: binding.skillID,
                baseline: baseline,
                observedRoot: root,
                observedEntry: target
            )
        case .directory(let observed):
            let state: DistributionCopyObservationState
            if observed.rootIdentity != baseline.rootIdentity {
                state = .rootReplaced
            } else if observed.entryIdentity != baseline.entryIdentity {
                state = .targetReplaced
            } else if observed.contentFingerprint != baseline.contentFingerprint {
                state = .contentDrift
            } else if observed.physicalTreeDigest != baseline.physicalTreeDigest {
                state = .physicalDrift
            } else if source.snapshot.fingerprintDigest
                        != baseline.contentFingerprint.digest
                        || source.physicalTree.digest != baseline.physicalTreeDigest {
                state = .sourceChanged
            } else {
                state = .inSync
            }
            return copyObservation(
                state,
                skillID: binding.skillID,
                baseline: baseline,
                observed: observed
            )
        }
    }

    func observeUnmanaged(
        _ entry: DistributionTargetEntry
    ) throws -> DistributionTargetObservation {
        switch try fileSystem.observe(entry) {
        case .missing:
            .missing
        case .unavailable:
            .unavailable
        case .symlink, .unknown:
            .unknownObject
        }
    }

    func reconcile(
        skillID: SkillID,
        bindings: [DistributionBinding]? = nil
    ) throws -> DistributionReconcileResult {
        if try operationStore.repairRequiredOperations().contains(where: {
            $0.skillID == skillID
        }) {
            return DistributionReconcileResult(
                status: .needsRepair,
                observations: [:]
            )
        }
        if try operationStore.recoverableOperations().contains(where: {
            $0.skillID == skillID
        }) {
            return DistributionReconcileResult(
                status: .operationInProgress,
                observations: [:]
            )
        }
        let current = try bindings ?? bindingStore.load(skillID: skillID)
        let links = try linkOwnershipStore.load(skillID: skillID)
        let source = try fileSystem.copySource(for: skillID)
        var observations: [DistributionTargetEntry: DistributionTargetObservation] = [:]
        var drifted = false
        for binding in current {
            guard let entry = DistributionTargetCatalog.current.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ) else {
                drifted = true
                continue
            }
            let observation = try observeCurrent(
                entry,
                binding: binding,
                source: source,
                linkOwnership: links
            )
            observations[entry] = observation
            if binding.syncMode == .copy {
                guard case .copy(let copy) = observation,
                      copy.state == .inSync else {
                    drifted = true
                    continue
                }
            } else if observation != .managed(
                skillID: skillID,
                ssotDirectoryName: skillID.directoryName
            ) {
                drifted = true
            }
        }
        return DistributionReconcileResult(
            status: drifted ? .drifted : .inSync,
            observations: observations
        )
    }

    func makePreflight(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        expectedOldLinks: [DistributionLinkOwnership],
        source: DistributionCopySource,
        operationID: SSOTOperationID
    ) throws -> DistributionOperationPreflightV2 {
        guard try configurationStore.load(skillID: skillID)
                == plan.expectedOldConfigured,
              canonicalBindings(
                  try bindingStore.load(skillID: skillID)
              ) == canonicalBindings(expectedOldBindings),
              canonicalLinks(
                  try linkOwnershipStore.load(skillID: skillID)
              ) == canonicalLinks(expectedOldLinks) else {
            throw DistributionSymlinkExecutorError.conflict
        }
        try fileSystem.requireUnchanged(source, skillID: skillID)
        let actions = try plan.filesystemActions.enumerated().map { index, action in
            try makePreflightAction(
                index: index,
                action: action,
                skillID: skillID,
                oldBindings: expectedOldBindings,
                oldLinks: expectedOldLinks,
                source: source,
                operationID: operationID
            )
        }
        return DistributionOperationPreflightV2(
            wireVersion: 2,
            skillID: skillID.directoryName,
            ssotIdentity: try ManagedItemIdentityCodec.encode(source.ssotIdentity),
            absoluteSSOTTarget: source.absoluteTarget,
            sourceContent: DistributionFingerprintWireV2(
                try SkillContentFingerprint(
                    currentDigest: source.snapshot.fingerprintDigest
                )
            ),
            sourcePhysicalTree: DistributionTreeDigestWireV2(
                source.physicalTree.digest
            ),
            expectedOldConfigured: plan.expectedOldConfigured,
            desiredConfigured: plan.desiredConfigured,
            actions: actions
        )
    }

    private func makePreflightAction(
        index: Int,
        action: DistributionFilesystemAction,
        skillID: SkillID,
        oldBindings: [DistributionBinding],
        oldLinks: [DistributionLinkOwnership],
        source: DistributionCopySource,
        operationID: SSOTOperationID
    ) throws -> DistributionOperationPreflightActionV2 {
        let old = oldBindings.first {
            $0.scope == action.entry.target.scope
                && $0.distributionSlug == action.entry.distributionSlug
        }
        let oldLink = oldLinks.first {
            $0.targetScopeKey == action.entry.target.scope.targetScopeKey
        }
        let observation = try old.map {
            try observeCurrent(
                action.entry,
                binding: $0,
                source: source,
                linkOwnership: oldLinks
            )
        } ?? observeUnmanaged(action.entry)
        try requirePreflightObservation(
            action.kind,
            observation: observation,
            skillID: skillID
        )
        let root = try fileSystem.existingRoot(for: action.entry.target.scope)
        return try DistributionOperationPreflightActionV2(
            actionIndex: index,
            kind: action.kind.rawValue,
            targetScopeKey: action.entry.target.scope.targetScopeKey,
            slug: action.entry.distributionSlug.value,
            rootIdentity: root.map(ManagedItemIdentityCodec.encode),
            oldCopy: old?.copyBaseline.map {
                try DistributionCopyEvidenceWireV2(
                    DistributionCopyEvidence(
                        rootIdentity: $0.rootIdentity,
                        entryIdentity: $0.entryIdentity,
                        contentFingerprint: $0.contentFingerprint,
                        physicalTreeDigest: $0.physicalTreeDigest
                    )
                )
            },
            oldLink: oldLink.map {
                try DistributionLinkEvidenceWireV2(
                    DistributionSymlinkEvidence(
                        rootIdentity: $0.rootIdentity,
                        entryIdentity: $0.entryIdentity,
                        absoluteTarget: $0.absoluteLinkTarget
                    )
                )
            },
            stagingName: action.kind.createsCopy
                ? DistributionSymlinkFileSystem.copyTemporaryName(
                    operationID: operationID.uuid,
                    actionIndex: index,
                    suffix: "staging"
                )
                : nil,
            quarantineName: action.kind.removesExisting
                ? quarantineName(
                    for: action.kind,
                    operationID: operationID,
                    actionIndex: index
                )
                : nil
        )
    }

    func encodeBindings(_ bindings: [DistributionBinding]) throws -> Data {
        try DistributionOperationPayloadCodec.encode(
            bindings.map(DistributionBindingWireV2.init)
        )
    }

    private func requirePreflightObservation(
        _ kind: DistributionFilesystemActionKind,
        observation: DistributionTargetObservation,
        skillID: SkillID
    ) throws {
        switch kind {
        case .createSymlink, .createCopy:
            guard observation == .missing else {
                throw DistributionSymlinkExecutorError.conflict
            }
        case .removeSymlink, .replaceSymlinkWithCopy:
            guard observation == .managed(
                skillID: skillID,
                ssotDirectoryName: skillID.directoryName
            ) else {
                throw DistributionSymlinkExecutorError.conflict
            }
        case .refreshCopy:
            guard case .copy(let copy) = observation,
                  copy.state == .sourceChanged else {
                throw DistributionSymlinkExecutorError.conflict
            }
        case .removeCopy, .replaceCopyWithSymlink:
            guard case .copy(let copy) = observation,
                  copy.state == .inSync || copy.state == .sourceChanged else {
                throw DistributionSymlinkExecutorError.conflict
            }
        }
    }

    private func copyObservation(
        _ state: DistributionCopyObservationState,
        skillID: SkillID,
        baseline: DistributionCopyBaseline?,
        observed: DistributionCopyEvidence? = nil,
        observedRoot: ManagedItemIdentity? = nil,
        observedEntry: ManagedItemIdentity? = nil
    ) -> DistributionTargetObservation {
        .copy(DistributionCopyObservation(
            state: state,
            evidence: DistributionCopyConflictEvidence(
                skillID: skillID,
                baselineContentFingerprint: baseline?.contentFingerprint,
                observedContentFingerprint: observed?.contentFingerprint,
                baselinePhysicalTreeDigest: baseline?.physicalTreeDigest,
                observedPhysicalTreeDigest: observed?.physicalTreeDigest,
                baselineRootIdentity: baseline?.rootIdentity,
                observedRootIdentity: observed?.rootIdentity ?? observedRoot,
                baselineEntryIdentity: baseline?.entryIdentity,
                observedEntryIdentity: observed?.entryIdentity ?? observedEntry
            )
        ))
    }

    private func quarantineName(
        for kind: DistributionFilesystemActionKind,
        operationID: SSOTOperationID,
        actionIndex: Int
    ) -> String {
        switch kind {
        case .removeSymlink, .replaceSymlinkWithCopy:
            DistributionSymlinkFileSystem.temporaryName(
                operationID: operationID.uuid,
                actionIndex: actionIndex
            )
        case .refreshCopy, .removeCopy, .replaceCopyWithSymlink:
            DistributionSymlinkFileSystem.copyTemporaryName(
                operationID: operationID.uuid,
                actionIndex: actionIndex,
                suffix: "quarantine"
            )
        case .createSymlink, .createCopy:
            ""
        }
    }

    private func canonicalBindings(
        _ bindings: [DistributionBinding]
    ) -> [DistributionBinding] {
        bindings.sorted {
            distributionBindingIntentPrecedes($0.intent, $1.intent)
        }
    }

    private func canonicalLinks(
        _ links: [DistributionLinkOwnership]
    ) -> [DistributionLinkOwnership] {
        links.sorted {
            $0.targetScopeKey.utf8.lexicographicallyPrecedes(
                $1.targetScopeKey.utf8
            )
        }
    }
}

nonisolated extension DistributionFilesystemActionKind {
    var removesExisting: Bool {
        switch self {
        case .removeSymlink, .refreshCopy, .removeCopy,
             .replaceSymlinkWithCopy, .replaceCopyWithSymlink:
            true
        case .createSymlink, .createCopy:
            false
        }
    }
}
