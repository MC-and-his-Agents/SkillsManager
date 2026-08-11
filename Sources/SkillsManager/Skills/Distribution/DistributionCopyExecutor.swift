import Foundation

nonisolated struct DistributionCopyExecutorHooks: Sendable {
    var afterDatabaseCommit: @Sendable () throws -> Void = {}
}

/// Copy-aware action-backed operations share the existing planner, journal,
/// stores, and descriptor-backed distribution file system.
nonisolated final class DistributionCopyExecutor {
    let bindingStore: DistributionBindingStore
    let configurationStore: DistributionConfigurationStore
    let linkOwnershipStore: DistributionLinkOwnershipStore
    let operationStore: DistributionOperationStore
    let backupStore: SkillBackupStore
    let fileSystem: DistributionSymlinkFileSystem
    let backupFileSystem: SkillBackupFileSystem?
    let nowMilliseconds: () -> Int64
    let hooks: DistributionCopyExecutorHooks

    init(
        connection: SQLiteConnection,
        fileSystem: DistributionSymlinkFileSystem,
        backupFileSystem: SkillBackupFileSystem? = nil,
        hooks: DistributionCopyExecutorHooks = .init(),
        nowMilliseconds: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) throws {
        bindingStore = DistributionBindingStore(connection: connection)
        configurationStore = DistributionConfigurationStore(connection: connection)
        linkOwnershipStore = DistributionLinkOwnershipStore(connection: connection)
        operationStore = try DistributionOperationStore(connection: connection)
        backupStore = try SkillBackupStore(connection: connection)
        self.fileSystem = fileSystem
        self.backupFileSystem = backupFileSystem
        self.hooks = hooks
        self.nowMilliseconds = nowMilliseconds
    }

    func absoluteTargetURL(for entry: DistributionTargetEntry) throws -> URL {
        try fileSystem.absoluteTargetURL(for: entry)
    }

    func dryRun(
        skillID: SkillID,
        currentBindings: [DistributionBinding],
        desiredConfiguration: DistributionDesiredConfiguration,
        desiredConfigured: Bool = true,
        requiredAdapterCodes: Set<String>,
        catalog: DistributionTargetCatalog = .current
    ) throws -> DistributionPlan {
        let source = try fileSystem.copySource(for: skillID)
        let linkOwnership = try linkOwnershipStore.load(skillID: skillID)
        var observations: [DistributionTargetEntry: DistributionTargetObservation] = [:]
        let desiredIntents = desiredBindingIntents(
            skillID: skillID,
            configuration: desiredConfiguration
        )
        let candidates = currentBindings.map(\.intent) + desiredIntents
        for intent in candidates {
            guard let entry = catalog.entry(
                for: intent.scope,
                slug: intent.distributionSlug
            ), observations[entry] == nil else { continue }
            if let current = currentBindings.first(where: {
                $0.scope == intent.scope && $0.distributionSlug == intent.distributionSlug
            }) {
                observations[entry] = try observeCurrent(
                    entry,
                    binding: current,
                    source: source,
                    linkOwnership: linkOwnership
                )
            } else {
                observations[entry] = try observeUnmanaged(entry)
            }
        }
        return DistributionPlanner().plan(
            skillID: skillID,
            currentBindings: currentBindings,
            currentConfigured: try configurationStore.load(skillID: skillID),
            desiredConfiguration: desiredConfiguration,
            desiredConfigured: desiredConfigured,
            requiredAdapterCodes: requiredAdapterCodes,
            observations: observations,
            catalog: catalog
        )
    }

    func apply(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        approvedCopyDrift: DistributionCopyEvidence? = nil,
        approvedCopySource: DistributionCopySourceEvidence? = nil,
        approvedHistoricalMigration: DistributionHistoricalMigrationApproval? = nil,
        operationID requestedOperationID: SSOTOperationID? = nil,
        nowMilliseconds: Int64? = nil
    ) throws -> DistributionOperationRecord {
        guard plan.status == .executable,
              plan.filesystemActions.contains(where: { $0.kind.requiresV2 }) else {
            throw DistributionSymlinkExecutorError.conflict
        }
        let discardActions = plan.filesystemActions.filter {
            $0.kind == .discardCopyDrift
        }
        let historicalActions = approvedHistoricalMigration == nil
            ? []
            : plan.filesystemActions.filter { action in
                guard action.kind == .replaceCopyWithSymlink || action.kind == .removeCopy else {
                    return false
                }
                // A convergence cleanup can replace a stale ordinary directory
                // at an existing binding, or remove an extra directory beside
                // the selected binding. Both use the same historical backup contract.
                return true
            }
        let requiresApprovedCopySource = !discardActions.isEmpty || !historicalActions.isEmpty
        guard discardActions.isEmpty == (approvedCopyDrift == nil),
              requiresApprovedCopySource == (approvedCopySource != nil),
              discardActions.count <= 1,
              discardActions.isEmpty || plan.filesystemActions.count == 1 else {
            throw DistributionSymlinkExecutorError.conflict
        }
        guard historicalActions.isEmpty == (approvedHistoricalMigration == nil),
              historicalActions.count <= 1,
              historicalActions.isEmpty || plan.filesystemActions.count == 1 else {
            throw DistributionSymlinkExecutorError.conflict
        }
        let timestamp = nowMilliseconds ?? self.nowMilliseconds()
        guard timestamp >= 0,
              try operationStore.repairRequiredOperations().allSatisfy({
                  $0.skillID != skillID
              }),
              try operationStore.recoverableOperations().allSatisfy({
                  $0.skillID != skillID
              }) else {
            throw DistributionSymlinkExecutorError.operationInProgress
        }
        let operationID = requestedOperationID ?? SSOTOperationID()
        if let approvedHistoricalMigration {
            try requireHistoricalMigrationApproval(
                approvedHistoricalMigration,
                action: historicalActions[0],
                operationID: operationID
            )
        }
        let formatVersion = operationFormatVersion(for: expectedOldBindings)
        let oldLinks = try linkOwnershipStore.load(skillID: skillID)
        let source = try fileSystem.copySource(for: skillID)
        if let approvedCopySource,
           try source.decisionEvidence() != approvedCopySource {
            throw DistributionSymlinkExecutorError.conflict
        }
        let preflight: DistributionOperationPreflightV2
        preflight = try makePreflight(
            skillID: skillID,
            plan: plan,
            expectedOldBindings: expectedOldBindings,
            expectedOldLinks: oldLinks,
            source: source,
            operationID: operationID,
            approvedCopyDrift: approvedCopyDrift,
            approvedHistoricalMigration: approvedHistoricalMigration
        )
        var runtime = DistributionOperationRuntimeV2(
            wireVersion: 2,
            actions: plan.filesystemActions.indices.map {
                DistributionOperationRuntimeActionV2(
                    actionIndex: $0,
                    pending: nil,
                    stagedCopy: nil,
                    createdCopy: nil,
                    createdLink: nil,
                    quarantinedCopy: nil,
                    quarantinedLink: nil
                )
            }
        )
        let draft = try DistributionOperationDraft(
            formatVersion: formatVersion,
            operationID: operationID,
            skillID: skillID,
            oldBindings: try encodeBindings(
                expectedOldBindings,
                formatVersion: formatVersion
            ),
            newBindings: try encodeBindingIntents(
                plan.bindingReplacement,
                formatVersion: formatVersion
            ),
            planPayload: try plan.canonicalJSONData(),
            preflightPayload: try DistributionOperationPayloadCodec.encode(preflight),
            runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
            createdAtMilliseconds: timestamp
        )
        _ = try operationStore.transaction { try operationStore.insertPrepared(draft) }
        return try performApply(
            skillID: skillID,
            plan: plan,
            expectedOldBindings: expectedOldBindings,
            oldLinks: oldLinks,
            source: source,
            preflight: preflight,
            operationID: operationID,
            runtime: &runtime,
            timestamp: timestamp
        )
    }

    private func performApply(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        oldLinks: [DistributionLinkOwnership],
        source: DistributionCopySource,
        preflight: DistributionOperationPreflightV2,
        operationID: SSOTOperationID,
        runtime: inout DistributionOperationRuntimeV2,
        timestamp: Int64
    ) throws -> DistributionOperationRecord {
        do {
            try advance(
                operationID,
                phase: .applying,
                cursor: 0,
                runtime: runtime,
                timestamp: timestamp
            )
            try stageCopies(
                skillID: skillID,
                plan: plan,
                preflight: preflight,
                source: source,
                operationID: operationID,
                runtime: &runtime,
                timestamp: timestamp
            )
            try applyActions(
                skillID: skillID,
                plan: plan,
                preflight: preflight,
                source: source,
                operationID: operationID,
                runtime: &runtime,
                timestamp: timestamp
            )
            return try finalizeApply(
                skillID: skillID,
                plan: plan,
                expectedOldBindings: expectedOldBindings,
                oldLinks: oldLinks,
                source: source,
                preflight: preflight,
                operationID: operationID,
                runtime: runtime,
                timestamp: timestamp
            )
        } catch {
            try handleApplyFailure(
                error,
                operationID: operationID,
                plan: plan,
                preflight: preflight,
                runtime: runtime,
                expectedOldBindings: expectedOldBindings,
                expectedOldLinks: oldLinks,
                timestamp: timestamp
            )
            if preflight.actions.contains(where: {
                $0.historicalMigrationBackup != nil
            }), try operationStore.load(operationID).outcome == .needsRepair {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "distribution rollback requires repair"
                )
            }
            throw error
        }
    }

    private func finalizeApply(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        oldLinks: [DistributionLinkOwnership],
        source: DistributionCopySource,
        preflight: DistributionOperationPreflightV2,
        operationID: SSOTOperationID,
        runtime: DistributionOperationRuntimeV2,
        timestamp: Int64
    ) throws -> DistributionOperationRecord {
        try fileSystem.requireUnchanged(source, skillID: skillID)
        try requireHistoricalMigrationBackups(
            plan: plan,
            preflight: preflight,
            operationID: operationID
        )
        let desiredBindings = try finalizedBindings(
            plan,
            old: expectedOldBindings,
            source: source,
            runtime: runtime,
            operationID: operationID,
            timestamp: timestamp
        )
        let desiredLinks = try desiredLinkOwnership(
            skillID: skillID,
            plan: plan,
            bindings: desiredBindings,
            old: oldLinks,
            runtime: runtime,
            operationID: operationID,
            timestamp: timestamp
        )
        try requireFinalReadback(
            skillID: skillID,
            bindings: desiredBindings,
            links: desiredLinks
        )
        let current = try operationStore.load(operationID)
        try operationStore.markFilesystemAppliedActionBacked(
            operationID: operationID,
            newBindings: try encodeBindings(
                desiredBindings,
                formatVersion: current.formatVersion
            ),
            runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
            attemptCount: current.attemptCount + 1,
            updatedAtMilliseconds: max(timestamp, current.updatedAtMilliseconds)
        )
        try commitBindings(
            skillID: skillID,
            plan: plan,
            expectedOldBindings: expectedOldBindings,
            oldLinks: oldLinks,
            desiredBindings: desiredBindings,
            desiredLinks: desiredLinks,
            operationID: operationID,
            timestamp: timestamp
        )
        try hooks.afterDatabaseCommit()
        try finishCommitted(
            skillID: skillID,
            operationID: operationID,
            plan: plan,
            preflight: preflight,
            runtime: runtime,
            desiredBindings: desiredBindings,
            desiredLinks: desiredLinks,
            timestamp: timestamp
        )
        return try operationStore.load(operationID)
    }

    private func commitBindings(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        oldLinks: [DistributionLinkOwnership],
        desiredBindings: [DistributionBinding],
        desiredLinks: [DistributionLinkOwnership],
        operationID: SSOTOperationID,
        timestamp: Int64
    ) throws {
        try operationStore.transaction {
            _ = try bindingStore.replaceFinalizedInCurrentTransaction(
                skillID: skillID,
                expectedOld: expectedOldBindings,
                desired: desiredBindings
            )
            _ = try linkOwnershipStore.replaceInCurrentTransaction(
                skillID: skillID,
                expectedOld: oldLinks,
                desired: desiredLinks,
                appliedOperationID: operationID,
                nowMilliseconds: timestamp
            )
            try configurationStore.replaceInCurrentTransaction(
                skillID: skillID,
                expectedOld: plan.expectedOldConfigured,
                desired: plan.desiredConfigured,
                nowMilliseconds: timestamp
            )
            let sealed = try operationStore.load(operationID)
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .databaseCommitted,
                forwardCursor: Int64(plan.filesystemActions.count),
                rollbackCursor: 0,
                cleanupCursor: 0,
                runtimePayload: sealed.runtimePayload,
                attemptCount: sealed.attemptCount + 1,
                lastError: nil,
                updatedAtMilliseconds: max(timestamp, sealed.updatedAtMilliseconds)
            )
        }
    }

    private func stageCopies(
        skillID: SkillID,
        plan: DistributionPlan,
        preflight: DistributionOperationPreflightV2,
        source: DistributionCopySource,
        operationID: SSOTOperationID,
        runtime: inout DistributionOperationRuntimeV2,
        timestamp: Int64
    ) throws {
        for (index, action) in plan.filesystemActions.enumerated()
        where action.kind.createsCopy {
            let root = try fileSystem.ensureRoot(for: action.entry.target.scope)
            if let encodedRoot = preflight.actions[index].rootIdentity,
               try ManagedItemIdentityCodec.decode(encodedRoot) != root {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "distribution root changed"
                )
            }
            runtime.actions[index].pending = .stageCopy
            try advance(
                operationID,
                phase: .applying,
                cursor: 0,
                runtime: runtime,
                timestamp: timestamp
            )
            let staged = try fileSystem.stageCopy(
                action.entry,
                source: source,
                expectedRootIdentity: root,
                operationID: operationID.uuid,
                actionIndex: index
            )
            guard staged.temporaryName == preflight.actions[index].stagingName else {
                throw DistributionSymlinkExecutorError.needsRepair("staging locator changed")
            }
            runtime.actions[index].stagedCopy = try DistributionCopyEvidenceWireV2(
                staged.evidence
            )
            runtime.actions[index].pending = nil
            try advance(
                operationID,
                phase: .applying,
                cursor: 0,
                runtime: runtime,
                timestamp: timestamp
            )
            try fileSystem.requireUnchanged(source, skillID: skillID)
        }
    }

    private func applyActions(
        skillID: SkillID,
        plan: DistributionPlan,
        preflight: DistributionOperationPreflightV2,
        source: DistributionCopySource,
        operationID: SSOTOperationID,
        runtime: inout DistributionOperationRuntimeV2,
        timestamp: Int64
    ) throws {
        for (index, action) in plan.filesystemActions.enumerated() {
            try requireHistoricalMigrationBackup(
                action: action,
                preflightAction: preflight.actions[index],
                operationID: operationID
            )
            switch action.kind {
            case .removeSymlink:
                try quarantineLink(
                    action, index, preflight, operationID, &runtime, timestamp
                )
            case .createSymlink:
                try createLink(
                    action, index, preflight, source, operationID, &runtime, timestamp
                )
            case .createCopy:
                try promoteCopy(action, index, preflight, &runtime, operationID, timestamp)
            case .refreshCopy, .discardCopyDrift:
                try quarantineCopy(
                    action, index, preflight, operationID, &runtime, timestamp
                )
                try promoteCopy(action, index, preflight, &runtime, operationID, timestamp)
            case .removeCopy:
                try quarantineCopy(
                    action, index, preflight, operationID, &runtime, timestamp
                )
            case .replaceSymlinkWithCopy:
                try quarantineLink(
                    action, index, preflight, operationID, &runtime, timestamp
                )
                try promoteCopy(action, index, preflight, &runtime, operationID, timestamp)
            case .replaceCopyWithSymlink:
                try quarantineCopy(
                    action, index, preflight, operationID, &runtime, timestamp
                )
                try createLink(
                    action, index, preflight, source, operationID, &runtime, timestamp
                )
            }
            runtime.actions[index].pending = nil
            try advance(
                operationID,
                phase: .applying,
                cursor: Int64(index + 1),
                runtime: runtime,
                timestamp: timestamp
            )
            try fileSystem.requireUnchanged(source, skillID: skillID)
        }
    }

    func advance(
        _ operationID: SSOTOperationID,
        phase: DistributionOperationPhase,
        cursor: Int64,
        runtime: DistributionOperationRuntimeV2,
        timestamp: Int64
    ) throws {
        let current = try operationStore.load(operationID)
        try operationStore.updateProgress(
            operationID: operationID,
            phase: phase,
            forwardCursor: max(cursor, current.forwardCursor),
            rollbackCursor: current.rollbackCursor,
            cleanupCursor: current.cleanupCursor,
            runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
            attemptCount: current.attemptCount + 1,
            lastError: current.lastError,
            updatedAtMilliseconds: max(timestamp, current.updatedAtMilliseconds)
        )
    }
}

nonisolated extension DistributionFilesystemActionKind {
    var requiresV2: Bool {
        switch self {
        case .removeSymlink, .createSymlink: false
        default: true
        }
    }

    var createsCopy: Bool {
        switch self {
        case .createCopy, .refreshCopy, .discardCopyDrift,
             .replaceSymlinkWithCopy: true
        default: false
        }
    }
}
