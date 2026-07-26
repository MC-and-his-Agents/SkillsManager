import Foundation

nonisolated enum DistributionReconcileStatus: String, Sendable {
    case inSync
    case drifted
    case needsRepair
    case operationInProgress
}

nonisolated struct DistributionReconcileResult: Sendable, Equatable {
    let status: DistributionReconcileStatus
    let observations: [DistributionTargetEntry: DistributionTargetObservation]
}

private nonisolated struct DistributionBindingPayload: Codable, Equatable {
    let skillID: String
    let scope: String
    let adapter: String?
    let slug: String
    let syncMode: String

    init(_ intent: DistributionBindingIntent) {
        skillID = intent.skillID.directoryName
        switch intent.scope {
        case .global:
            scope = "global"
            adapter = nil
        case .agent(let value):
            scope = "agent"
            adapter = value.storageKey
        }
        slug = intent.distributionSlug.value
        syncMode = intent.syncMode.rawValue
    }
}

private nonisolated struct DistributionPreflightAction: Codable {
    let kind: String
    let targetScopeKey: String
    let slug: String
    let absoluteLinkTarget: String
    let rootIdentity: Data
    let entryIdentity: Data?
}

private nonisolated struct DistributionRuntimeEvidence: Codable {
    struct Created: Codable {
        let actionIndex: Int
        let rootIdentity: Data
        let entryIdentity: Data
        let absoluteLinkTarget: String
    }

    struct Removed: Codable {
        let actionIndex: Int
        let temporaryName: String
        let rootIdentity: Data
        let entryIdentity: Data
        let absoluteLinkTarget: String
    }

    var created: [Created] = []
    var removed: [Removed] = []
}

nonisolated enum DistributionSymlinkExecutorError: Error, Equatable, LocalizedError {
    case blocked([DistributionPlanConflict])
    case conflict
    case needsRepair(String)
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .blocked(let conflicts):
            "Distribution plan is blocked by \(conflicts.count) conflict(s)."
        case .conflict:
            "Distribution state changed while the operation was being prepared."
        case .needsRepair(let detail):
            "Distribution needs repair: \(detail)"
        case .operationInProgress:
            "A distribution operation is already in progress for this Skill."
        }
    }
}

/// The bounded write-side coordinator for the planner and descriptor-backed file system.
nonisolated final class DistributionSymlinkExecutor {
    private let bindingStore: DistributionBindingStore
    private let ownershipStore: DistributionLinkOwnershipStore
    private let operationStore: DistributionOperationStore
    private let fileSystem: DistributionSymlinkFileSystem
    private let nowMilliseconds: () -> Int64

    init(
        connection: SQLiteConnection,
        fileSystem: DistributionSymlinkFileSystem,
        nowMilliseconds: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) throws {
        bindingStore = DistributionBindingStore(connection: connection)
        ownershipStore = DistributionLinkOwnershipStore(connection: connection)
        operationStore = try DistributionOperationStore(connection: connection)
        self.fileSystem = fileSystem
        self.nowMilliseconds = nowMilliseconds
    }

    func dryRun(
        skillID: SkillID,
        currentBindings: [DistributionBinding],
        desiredScope: DistributionDesiredScope,
        requiredAdapterCodes: Set<String>,
        catalog: DistributionTargetCatalog = .current
    ) throws -> DistributionPlan {
        let ownership = try ownershipStore.load(skillID: skillID)
        var observations: [DistributionTargetEntry: DistributionTargetObservation] = [:]
        let scopes = Set(currentBindings.map(\.scope))
            .union(desiredScope.scopes)
        for scope in scopes {
            guard let slug = slug(for: scope, current: currentBindings, desired: desiredScope),
                  let entry = catalog.entry(for: scope, slug: slug) else { continue }
            observations[entry] = try observe(
                entry: entry,
                skillID: skillID,
                ownership: ownership
            )
        }
        return DistributionPlanner().plan(
            skillID: skillID,
            currentBindings: currentBindings,
            desiredScope: desiredScope,
            requiredAdapterCodes: requiredAdapterCodes,
            observations: observations,
            catalog: catalog
        )
    }

    func apply(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        expectedOldOwnership: [DistributionLinkOwnership],
        nowMilliseconds: Int64? = nil
    ) throws -> DistributionOperationRecord {
        guard plan.status == .executable else {
            if plan.status == .blocked { throw DistributionSymlinkExecutorError.blocked(plan.conflicts) }
            throw DistributionSymlinkExecutorError.conflict
        }
        let timestamp = nowMilliseconds ?? self.nowMilliseconds()
        guard timestamp >= 0 else { throw DistributionSymlinkExecutorError.conflict }
        guard try operationStore.repairRequiredOperations()
                .allSatisfy({ $0.skillID != skillID }) else {
            throw DistributionSymlinkExecutorError.needsRepair("a previous operation is unresolved")
        }
        guard try operationStore.recoverableOperations()
                .allSatisfy({ $0.skillID != skillID }) else {
            throw DistributionSymlinkExecutorError.operationInProgress
        }

        let preflight = try makePreflight(
            skillID: skillID,
            plan: plan,
            expectedOldBindings: expectedOldBindings,
            expectedOldOwnership: expectedOldOwnership
        )
        let operationID = SSOTOperationID()
        let runtime = DistributionRuntimeEvidence()
        let draft = try DistributionOperationDraft(
            operationID: operationID,
            skillID: skillID,
            oldBindings: try DistributionOperationPayloadCodec.encode(
                expectedOldBindings.map { DistributionBindingPayload($0.intent) }
            ),
            newBindings: try DistributionOperationPayloadCodec.encode(
                plan.bindingReplacement.map(DistributionBindingPayload.init)
            ),
            planPayload: try plan.canonicalJSONData(),
            preflightPayload: try DistributionOperationPayloadCodec.encode(preflight),
            runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
            createdAtMilliseconds: timestamp
        )
        _ = try operationStore.transaction {
            try operationStore.insertPrepared(draft)
        }
        var record = try operationStore.load(operationID)
        var quarantined: [Int: DistributionQuarantinedSymlink] = [:]
        var created: [Int: DistributionSymlinkEvidence] = [:]
        do {
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .applying,
                forwardCursor: 0,
                rollbackCursor: 0,
                cleanupCursor: 0,
                runtimePayload: draft.runtimePayload,
                attemptCount: 1,
                lastError: nil,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )
            for (index, action) in plan.filesystemActions.enumerated() {
                switch action.kind {
                case .removeSymlink:
                    guard let ownership = expectedOldOwnership.first(where: {
                        $0.targetScopeKey == action.entry.target.scope.targetScopeKey
                    }) else { throw DistributionSymlinkExecutorError.conflict }
                    let evidence = DistributionSymlinkEvidence(
                        rootIdentity: ownership.rootIdentity,
                        entryIdentity: ownership.entryIdentity,
                        absoluteTarget: ownership.absoluteLinkTarget
                    )
                    quarantined[index] = try fileSystem.quarantine(
                        action.entry,
                        expected: evidence,
                        operationID: operationID.uuid,
                        actionIndex: index
                    )
                case .createSymlink:
                    let rootIdentity = try fileSystem.ensureRoot(for: action.entry.target.scope)
                    let evidence = try fileSystem.create(
                        action.entry,
                        absoluteTarget: try fileSystem.ssotEvidence(for: skillID).absoluteTarget,
                        expectedRootIdentity: rootIdentity
                    )
                    created[index] = evidence
                }
                try operationStore.updateProgress(
                    operationID: operationID,
                    phase: .applying,
                    forwardCursor: Int64(index + 1),
                    rollbackCursor: 0,
                    cleanupCursor: 0,
                    runtimePayload: try runtimePayload(created: created, quarantined: quarantined),
                    attemptCount: Int64(index + 2),
                    lastError: nil,
                    updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
                )
                record = try operationStore.load(operationID)
            }
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .filesystemApplied,
                forwardCursor: Int64(plan.filesystemActions.count),
                rollbackCursor: 0,
                cleanupCursor: 0,
                runtimePayload: try runtimePayload(created: created, quarantined: quarantined),
                attemptCount: record.attemptCount + 1,
                lastError: nil,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )

            let desiredOwnership = try makeDesiredOwnership(
                skillID: skillID,
                plan: plan,
                oldOwnership: expectedOldOwnership,
                created: created,
                operationID: operationID,
                timestamp: timestamp
            )
            try operationStore.transaction {
                _ = try bindingStore.replaceInCurrentTransaction(
                    skillID: skillID,
                    expectedOld: expectedOldBindings,
                    desired: plan.bindingReplacement,
                    nowMilliseconds: timestamp
                )
                _ = try ownershipStore.replaceInCurrentTransaction(
                    skillID: skillID,
                    expectedOld: expectedOldOwnership,
                    desired: desiredOwnership,
                    appliedOperationID: operationID,
                    nowMilliseconds: timestamp
                )
                try operationStore.updateProgress(
                    operationID: operationID,
                    phase: .databaseCommitted,
                    forwardCursor: Int64(plan.filesystemActions.count),
                    rollbackCursor: 0,
                    cleanupCursor: 0,
                    runtimePayload: try runtimePayload(created: created, quarantined: quarantined),
                    attemptCount: record.attemptCount + 2,
                    lastError: nil,
                    updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
                )
            }
            for (index, item) in quarantined {
                try fileSystem.cleanup(plan.filesystemActions[index].entry, quarantined: item)
            }
            try operationStore.complete(
                operationID: operationID,
                outcome: .applied,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )
            return try operationStore.load(operationID)
        } catch {
            do {
                for (index, evidence) in created.sorted(by: { $0.key > $1.key }) {
                    try? fileSystem.removeCreated(plan.filesystemActions[index].entry, expected: evidence)
                }
                for (index, item) in quarantined.sorted(by: { $0.key > $1.key }) {
                    try? fileSystem.restore(plan.filesystemActions[index].entry, quarantined: item)
                }
                if let current = try? operationStore.load(operationID),
                   current.phase != .databaseCommitted {
                    try? operationStore.complete(
                        operationID: operationID,
                        outcome: .rolledBack,
                        updatedAtMilliseconds: max(timestamp, current.updatedAtMilliseconds)
                    )
                } else {
                    try? operationStore.markNeedsRepair(
                        operationID: operationID,
                        detail: error.localizedDescription,
                        updatedAtMilliseconds: timestamp
                    )
                }
            }
            throw error
        }
    }

    func reconcile(
        skillID: SkillID,
        bindings: [DistributionBinding]? = nil
    ) throws -> DistributionReconcileResult {
        if try operationStore.repairRequiredOperations().contains(where: { $0.skillID == skillID }) {
            return DistributionReconcileResult(status: .needsRepair, observations: [:])
        }
        if try operationStore.recoverableOperations().contains(where: { $0.skillID == skillID }) {
            return DistributionReconcileResult(status: .operationInProgress, observations: [:])
        }
        let current = try bindings ?? bindingStore.load(skillID: skillID)
        let ownership = try ownershipStore.load(skillID: skillID)
        var observations: [DistributionTargetEntry: DistributionTargetObservation] = [:]
        var drifted = false
        for binding in current {
            let entry = DistributionTargetCatalog.current.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            )!
            let result = try observe(entry: entry, skillID: skillID, ownership: ownership)
            observations[entry] = result
            if result != .managed(skillID: skillID, ssotDirectoryName: skillID.directoryName) {
                drifted = true
            }
        }
        return DistributionReconcileResult(status: drifted ? .drifted : .inSync, observations: observations)
    }

    func recoverAll() throws {
        for operation in try operationStore.recoverableOperations() {
            // A durable runtime phase without captured evidence is deliberately fail-closed.
            try operationStore.markNeedsRepair(
                operationID: operation.operationID,
                detail: "recovery requires a fresh preflight",
                updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
            )
        }
    }

    private func makePreflight(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        expectedOldOwnership: [DistributionLinkOwnership]
    ) throws -> [DistributionPreflightAction] {
        let target = try fileSystem.ssotEvidence(for: skillID).absoluteTarget
        return try plan.filesystemActions.map { action in
            let observation = try observe(
                entry: action.entry,
                skillID: skillID,
                ownership: expectedOldOwnership
            )
            switch action.kind {
            case .createSymlink:
                guard observation == .missing else { throw DistributionSymlinkExecutorError.conflict }
                let root = try fileSystem.existingRoot(for: action.entry.target.scope)
                return DistributionPreflightAction(
                    kind: action.kind.rawValue,
                    targetScopeKey: action.entry.target.scope.targetScopeKey,
                    slug: action.entry.distributionSlug.value,
                    absoluteLinkTarget: target,
                    rootIdentity: try root.map(ManagedItemIdentityCodec.encode) ?? Data(),
                    entryIdentity: nil
                )
            case .removeSymlink:
                guard let ownership = expectedOldOwnership.first(where: {
                    $0.targetScopeKey == action.entry.target.scope.targetScopeKey
                }), observation == .managed(skillID: skillID, ssotDirectoryName: skillID.directoryName)
                else { throw DistributionSymlinkExecutorError.conflict }
                return DistributionPreflightAction(
                    kind: action.kind.rawValue,
                    targetScopeKey: action.entry.target.scope.targetScopeKey,
                    slug: action.entry.distributionSlug.value,
                    absoluteLinkTarget: ownership.absoluteLinkTarget,
                rootIdentity: try ManagedItemIdentityCodec.encode(ownership.rootIdentity),
                    entryIdentity: try ManagedItemIdentityCodec.encode(ownership.entryIdentity)
                )
            }
        }
    }

    private func observe(
        entry: DistributionTargetEntry,
        skillID: SkillID,
        ownership: [DistributionLinkOwnership]
    ) throws -> DistributionTargetObservation {
        switch try fileSystem.observe(entry) {
        case .missing:
            return DistributionTargetObservation.missing
        case .unknown:
            return DistributionTargetObservation.unknownObject
        case .symlink(let root, let entryIdentity, let target):
            guard let row = ownership.first(where: {
                $0.targetScopeKey == entry.target.scope.targetScopeKey
            }), row.rootIdentity == root, row.entryIdentity == entryIdentity,
                  row.absoluteLinkTarget == target else { return .unknownObject }
            return DistributionTargetObservation.managed(
                skillID: skillID,
                ssotDirectoryName: skillID.directoryName
            )
        }
    }

    private func slug(
        for scope: DistributionBindingScope,
        current: [DistributionBinding],
        desired: DistributionDesiredScope
    ) -> DefaultDistributionSlug? {
        if let binding = current.first(where: { $0.scope == scope }) { return binding.distributionSlug }
        switch desired {
        case .global(let slug) where scope == .global:
            return slug
        case .agents(let adapters, let slug)
            where scope.adapter.map(adapters.contains) == true:
            return slug
        default:
            return nil
        }
    }

    private func runtimePayload(
        created: [Int: DistributionSymlinkEvidence],
        quarantined: [Int: DistributionQuarantinedSymlink]
    ) throws -> Data {
        let createdEvidence = try created.map {
            DistributionRuntimeEvidence.Created(
                actionIndex: $0.key,
                rootIdentity: try ManagedItemIdentityCodec.encode($0.value.rootIdentity),
                entryIdentity: try ManagedItemIdentityCodec.encode($0.value.entryIdentity),
                absoluteLinkTarget: $0.value.absoluteTarget
            )
        }.sorted { $0.actionIndex < $1.actionIndex }
        let removedEvidence = try quarantined.map {
            DistributionRuntimeEvidence.Removed(
                actionIndex: $0.key,
                temporaryName: $0.value.temporaryName,
                rootIdentity: try ManagedItemIdentityCodec.encode($0.value.evidence.rootIdentity),
                entryIdentity: try ManagedItemIdentityCodec.encode($0.value.evidence.entryIdentity),
                absoluteLinkTarget: $0.value.evidence.absoluteTarget
            )
        }.sorted { $0.actionIndex < $1.actionIndex }
        return try DistributionOperationPayloadCodec.encode(
            DistributionRuntimeEvidence(created: createdEvidence, removed: removedEvidence)
        )
    }

    private func makeDesiredOwnership(
        skillID: SkillID,
        plan: DistributionPlan,
        oldOwnership: [DistributionLinkOwnership],
        created: [Int: DistributionSymlinkEvidence],
        operationID: SSOTOperationID,
        timestamp: Int64
    ) throws -> [DistributionLinkOwnership] {
        try plan.bindingReplacement.map { binding in
            let actionIndex = plan.filesystemActions.firstIndex {
                $0.kind == .createSymlink
                    && $0.entry.target.scope == binding.scope
                    && $0.entry.distributionSlug == binding.distributionSlug
            }
            let evidence: DistributionSymlinkEvidence
            if let actionIndex, let captured = created[actionIndex] {
                evidence = captured
            } else if let old = oldOwnership.first(where: {
                $0.targetScopeKey == binding.scope.targetScopeKey
            }) {
                evidence = DistributionSymlinkEvidence(
                    rootIdentity: old.rootIdentity,
                    entryIdentity: old.entryIdentity,
                    absoluteTarget: old.absoluteLinkTarget
                )
            } else {
                throw DistributionSymlinkExecutorError.conflict
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
        }
    }
}

private extension DistributionDesiredScope {
    nonisolated var scopes: Set<DistributionBindingScope> {
        switch self {
        case .disabled: []
        case .global: [.global]
        case .agents(let adapters, _): Set(adapters.map(DistributionBindingScope.agent))
        }
    }
}
