import Foundation

nonisolated extension DistributionCopyExecutor {
    func finalizedBindings(
        _ plan: DistributionPlan,
        old: [DistributionBinding],
        source: DistributionCopySource,
        runtime: DistributionOperationRuntimeV2,
        operationID: SSOTOperationID,
        timestamp: Int64
    ) throws -> [DistributionBinding] {
        try plan.bindingReplacement.map { intent in
            let previous = old.first { $0.scope == intent.scope }
            let baseline: DistributionCopyBaseline?
            if intent.syncMode == .copy {
                if let created = createdCopyEvidence(
                    for: intent,
                    plan: plan,
                    runtime: runtime
                ) {
                    baseline = try DistributionCopyBaseline(
                        contentFingerprint: created.contentFingerprint,
                        physicalTreeDigest: created.physicalTreeDigest,
                        rootIdentity: created.rootIdentity,
                        entryIdentity: created.entryIdentity,
                        appliedOperationID: operationID,
                        verifiedAtMilliseconds: timestamp
                    )
                } else if let retained = previous,
                          retained.intent == intent,
                          let oldBaseline = retained.copyBaseline {
                    baseline = oldBaseline
                } else {
                    throw DistributionSymlinkExecutorError.needsRepair(
                        "Copy baseline evidence is missing"
                    )
                }
                guard baseline?.contentFingerprint.digest
                        == source.snapshot.fingerprintDigest,
                      baseline?.physicalTreeDigest == source.physicalTree.digest else {
                    throw DistributionSymlinkExecutorError.needsRepair(
                        "Copy readback differs from the SSOT source"
                    )
                }
            } else {
                baseline = nil
            }

            let createdAt = previous?.createdAtMilliseconds ?? timestamp
            let updatedAt: Int64
            if let previous,
               previous.intent == intent,
               previous.copyBaseline == baseline {
                updatedAt = previous.updatedAtMilliseconds
            } else if let previous {
                guard previous.updatedAtMilliseconds < Int64.max else {
                    throw DistributionSymlinkExecutorError.conflict
                }
                updatedAt = max(timestamp, previous.updatedAtMilliseconds + 1)
            } else {
                updatedAt = timestamp
            }
            return try DistributionBinding(
                skillID: intent.skillID,
                scope: intent.scope,
                distributionSlug: intent.distributionSlug,
                syncMode: intent.syncMode,
                copyBaseline: baseline,
                createdAtMilliseconds: createdAt,
                updatedAtMilliseconds: updatedAt
            )
        }.sorted {
            distributionBindingIntentPrecedes($0.intent, $1.intent)
        }
    }

    func desiredLinkOwnership(
        skillID: SkillID,
        plan: DistributionPlan,
        bindings: [DistributionBinding],
        old: [DistributionLinkOwnership],
        runtime: DistributionOperationRuntimeV2,
        operationID: SSOTOperationID,
        timestamp: Int64
    ) throws -> [DistributionLinkOwnership] {
        try bindings.compactMap { binding in
            guard binding.syncMode == .symlink else { return nil }
            let evidence: DistributionSymlinkEvidence
            if let created = createdLinkEvidence(
                for: binding.intent,
                plan: plan,
                runtime: runtime
            ) {
                evidence = created
            } else if let retained = old.first(where: {
                $0.targetScopeKey == binding.scope.targetScopeKey
            }) {
                evidence = DistributionSymlinkEvidence(
                    rootIdentity: retained.rootIdentity,
                    entryIdentity: retained.entryIdentity,
                    absoluteTarget: retained.absoluteLinkTarget
                )
            } else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "symlink ownership evidence is missing"
                )
            }
            return try DistributionLinkOwnership(
                skillID: skillID,
                targetScopeKey: binding.scope.targetScopeKey,
                appliedOperationID: operationID,
                rootIdentity: evidence.rootIdentity,
                entryIdentity: evidence.entryIdentity,
                absoluteLinkTarget: evidence.absoluteTarget,
                verifiedAtMilliseconds: timestamp
            )
        }.sorted {
            $0.targetScopeKey.utf8.lexicographicallyPrecedes(
                $1.targetScopeKey.utf8
            )
        }
    }

    func requireFinalReadback(
        skillID: SkillID,
        bindings: [DistributionBinding],
        links: [DistributionLinkOwnership]
    ) throws {
        let source = try fileSystem.ssotEvidence(for: skillID)
        let symlinkBindings = bindings.filter { $0.syncMode == .symlink }
        guard links.count == symlinkBindings.count,
              Set(links.map(\.targetScopeKey)).count == links.count else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "symlink ownership readback is incomplete"
            )
        }
        for binding in bindings {
            guard let entry = fileSystem.catalog.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ) else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "distribution target is unavailable"
                )
            }
            if binding.syncMode == .copy {
                guard let baseline = binding.copyBaseline,
                      case .directory(let evidence) = try fileSystem.observeCopy(entry),
                      evidence.rootIdentity == baseline.rootIdentity,
                      evidence.entryIdentity == baseline.entryIdentity,
                      evidence.contentFingerprint == baseline.contentFingerprint,
                      evidence.physicalTreeDigest == baseline.physicalTreeDigest else {
                    throw DistributionSymlinkExecutorError.needsRepair(
                        "Copy readback drifted"
                    )
                }
            } else {
                guard let ownership = links.first(where: {
                    $0.targetScopeKey == binding.scope.targetScopeKey
                }), ownership.absoluteLinkTarget == source.absoluteTarget,
                case .symlink(let root, let target, let absoluteTarget)
                    = try fileSystem.observe(entry),
                root == ownership.rootIdentity,
                target == ownership.entryIdentity,
                absoluteTarget == ownership.absoluteLinkTarget else {
                    throw DistributionSymlinkExecutorError.needsRepair(
                        "symlink readback drifted"
                    )
                }
            }
        }
    }

    func finishCommitted(
        skillID: SkillID,
        operationID: SSOTOperationID,
        plan: DistributionPlan,
        preflight: DistributionOperationPreflightV2,
        runtime: DistributionOperationRuntimeV2,
        desiredBindings: [DistributionBinding],
        desiredLinks: [DistributionLinkOwnership],
        timestamp: Int64
    ) throws {
        let current = try operationStore.load(operationID)
        if current.phase == .databaseCommitted {
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .cleaning,
                forwardCursor: current.forwardCursor,
                rollbackCursor: current.rollbackCursor,
                cleanupCursor: current.cleanupCursor,
                runtimePayload: current.runtimePayload,
                attemptCount: current.attemptCount + 1,
                lastError: current.lastError,
                updatedAtMilliseconds: max(timestamp, current.updatedAtMilliseconds)
            )
        }
        let items = try cleanupItems(
            plan: plan,
            preflight: preflight,
            runtime: runtime
        )
        var record = try operationStore.load(operationID)
        guard record.cleanupCursor <= Int64(items.count) else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "cleanup cursor exceeds evidence"
            )
        }
        for item in items.dropFirst(Int(record.cleanupCursor)) {
            try requireHistoricalMigrationBackups(
                plan: plan,
                preflight: preflight,
                operationID: operationID
            )
            try cleanup(item)
            record = try operationStore.load(operationID)
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .cleaning,
                forwardCursor: record.forwardCursor,
                rollbackCursor: record.rollbackCursor,
                cleanupCursor: record.cleanupCursor + 1,
                runtimePayload: record.runtimePayload,
                attemptCount: record.attemptCount + 1,
                lastError: record.lastError,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )
        }
        let originCleanups = preflight.actions.compactMap(\.localOriginCleanup)
        guard originCleanups.count <= 1 else {
            throw try markOriginCleanupNeedsRepair(
                operationID: operationID,
                detail: "multiple historical origin cleanup intents",
                timestamp: timestamp
            )
        }
        guard try bindingStore.load(skillID: skillID)
                == desiredBindings,
              try linkOwnershipStore.load(skillID: skillID)
                == desiredLinks else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "database readback drifted"
            )
        }
        try requireFinalReadback(
            skillID: skillID,
            bindings: desiredBindings,
            links: desiredLinks
        )
        if let originCleanup = originCleanups.first {
            do {
                try localOriginStore.removeLocalOrigin(originCleanup.origin())
            } catch {
                throw try markOriginCleanupNeedsRepair(
                    operationID: operationID,
                    detail: error.localizedDescription,
                    timestamp: timestamp
                )
            }
        }
        let terminal = try operationStore.load(operationID)
        try operationStore.complete(
            operationID: operationID,
            outcome: .applied,
            updatedAtMilliseconds: max(timestamp, terminal.updatedAtMilliseconds)
        )
    }

    private enum CleanupItem {
        case copy(DistributionTargetEntry, DistributionQuarantinedCopy)
        case link(DistributionTargetEntry, DistributionQuarantinedSymlink)
    }

    private func cleanupItems(
        plan: DistributionPlan,
        preflight: DistributionOperationPreflightV2,
        runtime: DistributionOperationRuntimeV2
    ) throws -> [CleanupItem] {
        try runtime.actions.compactMap { evidence in
            guard plan.filesystemActions.indices.contains(evidence.actionIndex),
                  preflight.actions.indices.contains(evidence.actionIndex) else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "cleanup action evidence is invalid"
                )
            }
            let entry = plan.filesystemActions[evidence.actionIndex].entry
            if let copy = evidence.quarantinedCopy,
               let name = preflight.actions[evidence.actionIndex].quarantineName {
                return .copy(
                    entry,
                    DistributionQuarantinedCopy(
                        temporaryName: name,
                        evidence: try copy.evidence()
                    )
                )
            }
            if let link = evidence.quarantinedLink,
               let name = preflight.actions[evidence.actionIndex].quarantineName {
                return .link(
                    entry,
                    DistributionQuarantinedSymlink(
                        temporaryName: name,
                        evidence: try link.evidence()
                    )
                )
            }
            return nil
        }
    }

    private func markOriginCleanupNeedsRepair(
        operationID: SSOTOperationID,
        detail: String,
        timestamp: Int64
    ) throws -> DistributionSymlinkExecutorError {
        try? operationStore.markNeedsRepair(
            operationID: operationID,
            detail: String(detail.prefix(4_096)),
            updatedAtMilliseconds: max(timestamp, nowMilliseconds())
        )
        return .needsRepair("historical local origin cleanup requires repair")
    }

    private func cleanup(_ item: CleanupItem) throws {
        switch item {
        case .copy(let entry, let value):
            try fileSystem.cleanupCopy(entry, quarantined: value)
        case .link(let entry, let value):
            try fileSystem.cleanup(entry, quarantined: value)
        }
    }

    private func createdCopyEvidence(
        for intent: DistributionBindingIntent,
        plan: DistributionPlan,
        runtime: DistributionOperationRuntimeV2
    ) -> DistributionCopyEvidence? {
        for action in runtime.actions {
            guard let wire = action.createdCopy,
                  plan.filesystemActions.indices.contains(action.actionIndex),
                  plan.filesystemActions[action.actionIndex].entry.target.scope
                    == intent.scope,
                  plan.filesystemActions[action.actionIndex].entry.distributionSlug
                    == intent.distributionSlug else {
                continue
            }
            return try? wire.evidence()
        }
        return nil
    }

    private func createdLinkEvidence(
        for intent: DistributionBindingIntent,
        plan: DistributionPlan,
        runtime: DistributionOperationRuntimeV2
    ) -> DistributionSymlinkEvidence? {
        for action in runtime.actions {
            guard let wire = action.createdLink,
                  plan.filesystemActions.indices.contains(action.actionIndex),
                  plan.filesystemActions[action.actionIndex].entry.target.scope
                    == intent.scope,
                  plan.filesystemActions[action.actionIndex].entry.distributionSlug
                    == intent.distributionSlug else {
                continue
            }
            return try? wire.evidence()
        }
        return nil
    }

}
