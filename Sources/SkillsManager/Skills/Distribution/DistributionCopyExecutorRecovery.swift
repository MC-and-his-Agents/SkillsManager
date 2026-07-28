import Foundation

nonisolated extension DistributionCopyExecutor {
    func handleApplyFailure(
        _ error: Error,
        operationID: SSOTOperationID,
        plan: DistributionPlan,
        preflight: DistributionOperationPreflightV2,
        runtime: DistributionOperationRuntimeV2,
        expectedOldBindings: [DistributionBinding],
        expectedOldLinks: [DistributionLinkOwnership],
        timestamp: Int64
    ) throws {
        let record = try operationStore.load(operationID)
        if record.phase == .databaseCommitted || record.phase == .cleaning {
            return
        }
        do {
            try rollbackToOld(
                operationID: operationID,
                plan: plan,
                preflight: preflight,
                runtime: runtime,
                expectedOldBindings: expectedOldBindings,
                expectedOldLinks: expectedOldLinks,
                detail: error.localizedDescription,
                timestamp: timestamp
            )
        } catch {
            try operationStore.markNeedsRepair(
                operationID: operationID,
                detail: error.localizedDescription,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )
        }
    }

    func rollbackToOld(
        operationID: SSOTOperationID,
        plan: DistributionPlan,
        preflight: DistributionOperationPreflightV2,
        runtime initialRuntime: DistributionOperationRuntimeV2,
        expectedOldBindings: [DistributionBinding],
        expectedOldLinks: [DistributionLinkOwnership],
        detail: String?,
        timestamp: Int64
    ) throws {
        var runtime = initialRuntime
        var record = try operationStore.load(operationID)
        if record.phase != .rollingBack {
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .rollingBack,
                forwardCursor: record.forwardCursor,
                rollbackCursor: record.rollbackCursor,
                cleanupCursor: 0,
                runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
                attemptCount: record.attemptCount + 1,
                lastError: detail,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )
            record = try operationStore.load(operationID)
        }
        let reverseIndices = Array(plan.filesystemActions.indices.reversed())
        guard record.rollbackCursor <= Int64(reverseIndices.count) else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "rollback cursor exceeds evidence"
            )
        }
        for index in reverseIndices.dropFirst(Int(record.rollbackCursor)) {
            try rollbackAction(
                index,
                action: plan.filesystemActions[index],
                operationPreflight: preflight,
                preflight: preflight.actions[index],
                runtime: &runtime
            )
            record = try operationStore.load(operationID)
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .rollingBack,
                forwardCursor: record.forwardCursor,
                rollbackCursor: record.rollbackCursor + 1,
                cleanupCursor: 0,
                runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
                attemptCount: record.attemptCount + 1,
                lastError: detail,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )
        }
        try requireOldReadback(
            operationID: operationID,
            preflight: preflight,
            bindings: expectedOldBindings,
            links: expectedOldLinks
        )
        let terminal = try operationStore.load(operationID)
        try operationStore.completeV2RolledBack(
            operationID: operationID,
            desiredBindings: try DistributionOperationPayloadCodec.encode(
                plan.bindingReplacement.map(DistributionBindingWireV2.init)
            ),
            runtimePayload: terminal.runtimePayload,
            updatedAtMilliseconds: max(timestamp, terminal.updatedAtMilliseconds)
        )
    }

    private func rollbackAction(
        _ index: Int,
        action: DistributionFilesystemAction,
        operationPreflight: DistributionOperationPreflightV2,
        preflight: DistributionOperationPreflightActionV2,
        runtime: inout DistributionOperationRuntimeV2
    ) throws {
        guard runtime.actions.indices.contains(index) else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "runtime action is missing"
            )
        }
        var evidence = runtime.actions[index]
        if evidence.pending != nil {
            try reconcilePendingRollback(
                action,
                operationPreflight: operationPreflight,
                preflight: preflight,
                evidence: &evidence
            )
        }
        if let created = evidence.createdLink {
            try fileSystem.removeCreated(
                action.entry,
                expected: created.evidence()
            )
            evidence.createdLink = nil
        }
        if let created = evidence.createdCopy {
            let value = try created.evidence()
            try fileSystem.discardOperationCopy(
                action.entry,
                name: action.entry.distributionSlug.value,
                expectedRootIdentity: value.rootIdentity,
                expectedContent: value.contentFingerprint,
                expectedPhysicalTree: value.physicalTreeDigest
            )
            evidence.createdCopy = nil
        }
        if let removed = evidence.quarantinedCopy,
           let name = preflight.quarantineName {
            try fileSystem.restoreCopy(
                action.entry,
                quarantined: DistributionQuarantinedCopy(
                    temporaryName: name,
                    evidence: try removed.evidence()
                )
            )
            evidence.quarantinedCopy = nil
        }
        if let removed = evidence.quarantinedLink,
           let name = preflight.quarantineName {
            try fileSystem.restore(
                action.entry,
                quarantined: DistributionQuarantinedSymlink(
                    temporaryName: name,
                    evidence: try removed.evidence()
                )
            )
            evidence.quarantinedLink = nil
        }
        if let staged = evidence.stagedCopy,
           let name = preflight.stagingName {
            let value = try staged.evidence()
            try fileSystem.discardOperationCopy(
                action.entry,
                name: name,
                expectedRootIdentity: value.rootIdentity,
                expectedContent: value.contentFingerprint,
                expectedPhysicalTree: value.physicalTreeDigest
            )
            evidence.stagedCopy = nil
        }
        evidence.pending = nil
        runtime.actions[index] = evidence
    }

    private func reconcilePendingRollback(
        _ action: DistributionFilesystemAction,
        operationPreflight: DistributionOperationPreflightV2,
        preflight: DistributionOperationPreflightActionV2,
        evidence: inout DistributionOperationRuntimeActionV2
    ) throws {
        switch evidence.pending {
        case .stageCopy:
            guard let name = preflight.stagingName else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "staging locator is missing"
                )
            }
            try discardPendingCopy(
                action,
                name: name,
                operationPreflight: operationPreflight,
                preflight: preflight
            )
            evidence.stagedCopy = nil
        case .quarantineCopy:
            guard let old = preflight.oldCopy,
                  let name = preflight.quarantineName else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "Copy rollback evidence is missing"
                )
            }
            try fileSystem.restoreCopy(
                action.entry,
                quarantined: DistributionQuarantinedCopy(
                    temporaryName: name,
                    evidence: old.evidence()
                )
            )
            evidence.quarantinedCopy = nil
        case .quarantineSymlink:
            guard let old = preflight.oldLink,
                  let name = preflight.quarantineName else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "symlink rollback evidence is missing"
                )
            }
            try fileSystem.restore(
                action.entry,
                quarantined: DistributionQuarantinedSymlink(
                    temporaryName: name,
                    evidence: old.evidence()
                )
            )
            evidence.quarantinedLink = nil
        case .promoteCopy:
            guard let staged = evidence.stagedCopy,
                  let name = preflight.stagingName else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "Copy promotion evidence is missing"
                )
            }
            let value = try staged.evidence()
            try fileSystem.discardOperationCopy(
                action.entry,
                name: action.entry.distributionSlug.value,
                expectedRootIdentity: value.rootIdentity,
                expectedContent: value.contentFingerprint,
                expectedPhysicalTree: value.physicalTreeDigest
            )
            try fileSystem.discardOperationCopy(
                action.entry,
                name: name,
                expectedRootIdentity: value.rootIdentity,
                expectedContent: value.contentFingerprint,
                expectedPhysicalTree: value.physicalTreeDigest
            )
            evidence.createdCopy = nil
            evidence.stagedCopy = nil
        case .createSymlink:
            try removePendingLink(
                action,
                operationPreflight: operationPreflight,
                preflight: preflight
            )
            evidence.createdLink = nil
        case nil:
            break
        }
        evidence.pending = nil
    }

    private func discardPendingCopy(
        _ action: DistributionFilesystemAction,
        name: String,
        operationPreflight: DistributionOperationPreflightV2,
        preflight: DistributionOperationPreflightActionV2
    ) throws {
        try fileSystem.discardOperationCopy(
            action.entry,
            name: name,
            expectedRootIdentity: try preflight.rootIdentity.map(
                ManagedItemIdentityCodec.decode
            ),
            expectedContent: try operationPreflight.sourceContent.fingerprint(),
            expectedPhysicalTree: try operationPreflight.sourcePhysicalTree.treeDigest()
        )
    }

    private func removePendingLink(
        _ action: DistributionFilesystemAction,
        operationPreflight: DistributionOperationPreflightV2,
        preflight: DistributionOperationPreflightActionV2
    ) throws {
        switch try fileSystem.observe(action.entry) {
        case .missing:
            return
        case .symlink(let root, let target, let absoluteTarget):
            if let expectedRoot = preflight.rootIdentity,
               try ManagedItemIdentityCodec.decode(expectedRoot) != root {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "pending symlink root changed"
                )
            }
            guard absoluteTarget == operationPreflight.absoluteSSOTTarget else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "pending symlink target changed"
                )
            }
            try fileSystem.removeCreated(
                action.entry,
                expected: DistributionSymlinkEvidence(
                    rootIdentity: root,
                    entryIdentity: target,
                    absoluteTarget: absoluteTarget
                )
            )
        case .unavailable, .unknown:
            throw DistributionSymlinkExecutorError.needsRepair(
                "pending symlink create is ambiguous"
            )
        }
    }

    private func requireOldReadback(
        operationID: SSOTOperationID,
        preflight: DistributionOperationPreflightV2,
        bindings: [DistributionBinding],
        links: [DistributionLinkOwnership]
    ) throws {
        let source = try fileSystem.ssotEvidence(for: operationIDSkillID(operationID))
        guard source.identity == (try ManagedItemIdentityCodec.decode(
            preflight.ssotIdentity
        )), source.absoluteTarget == preflight.absoluteSSOTTarget,
              try bindingStore.load(skillID: operationIDSkillID(operationID)) == bindings,
              try linkOwnershipStore.load(skillID: operationIDSkillID(operationID)) == links,
              try configurationStore.load(skillID: operationIDSkillID(operationID))
                == preflight.expectedOldConfigured else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "rollback database or SSOT readback drifted"
            )
        }
        try requireFinalReadback(
            skillID: operationIDSkillID(operationID),
            bindings: bindings,
            links: links
        )
    }

    private func operationIDSkillID(_ operationID: SSOTOperationID) throws -> SkillID {
        try operationStore.load(operationID).skillID
    }
}
