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
    let createdAtMilliseconds: Int64?
    let updatedAtMilliseconds: Int64?

    private enum CodingKeys: String, CodingKey {
        case skillID
        case scope
        case adapter
        case slug
        case syncMode
        case createdAtMilliseconds
        case updatedAtMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skillID = try container.decode(String.self, forKey: .skillID)
        scope = try container.decode(String.self, forKey: .scope)
        adapter = try container.decodeIfPresent(String.self, forKey: .adapter)
        slug = try container.decode(String.self, forKey: .slug)
        syncMode = try container.decode(String.self, forKey: .syncMode)
        createdAtMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .createdAtMilliseconds
        )
        updatedAtMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .updatedAtMilliseconds
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skillID, forKey: .skillID)
        try container.encode(scope, forKey: .scope)
        try container.encode(adapter, forKey: .adapter)
        try container.encode(slug, forKey: .slug)
        try container.encode(syncMode, forKey: .syncMode)
        try container.encodeIfPresent(createdAtMilliseconds, forKey: .createdAtMilliseconds)
        try container.encodeIfPresent(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
    }

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
        createdAtMilliseconds = nil
        updatedAtMilliseconds = nil
    }

    init(_ binding: DistributionBinding) {
        let payload = DistributionBindingPayload(binding.intent)
        skillID = payload.skillID
        scope = payload.scope
        adapter = payload.adapter
        slug = payload.slug
        syncMode = payload.syncMode
        createdAtMilliseconds = binding.createdAtMilliseconds
        updatedAtMilliseconds = binding.updatedAtMilliseconds
    }

    func intent(skillID: SkillID) throws -> DistributionBindingIntent {
        guard self.skillID == skillID.directoryName,
              let syncMode = DistributionSyncMode(rawValue: syncMode),
              let slug = try? DefaultDistributionSlug(validating: slug) else {
            throw DistributionSymlinkExecutorError.needsRepair("invalid binding snapshot")
        }
        let bindingScope: DistributionBindingScope
        switch scope {
        case "global" where adapter == nil:
            bindingScope = .global
        case "agent":
            guard let adapter,
                  let platform = SkillPlatform.allCases.first(where: {
                      $0.storageKey == adapter
                  }) else {
                throw DistributionSymlinkExecutorError.needsRepair("invalid binding scope")
            }
            bindingScope = .agent(platform)
        default:
            throw DistributionSymlinkExecutorError.needsRepair("invalid binding scope")
        }
        return DistributionBindingIntent(
            skillID: skillID,
            scope: bindingScope,
            distributionSlug: slug,
            syncMode: syncMode
        )
    }

    func binding(skillID: SkillID) throws -> DistributionBinding {
        guard let createdAtMilliseconds, let updatedAtMilliseconds else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "binding snapshot is missing timestamps"
            )
        }
        let intent = try intent(skillID: skillID)
        return try DistributionBinding(
            skillID: skillID,
            scope: intent.scope,
            distributionSlug: intent.distributionSlug,
            syncMode: intent.syncMode,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }
}

private nonisolated struct DistributionPreflightAction: Codable {
    let kind: String
    let targetScopeKey: String
    let slug: String
    let absoluteLinkTarget: String
    let ssotIdentity: Data
    let rootIdentity: Data
    let entryIdentity: Data?
    let temporaryName: String
}

private nonisolated struct DistributionRepairPreflightTarget: Codable {
    let targetScopeKey: String
    let slug: String
    let rootIdentity: Data
}

private nonisolated struct DistributionPreflightPayload: Codable {
    let actions: [DistributionPreflightAction]
    let ssotIdentity: Data
    let absoluteLinkTarget: String
    let expectedOldConfigured: Bool
    let desiredConfigured: Bool
    let repairTargets: [DistributionRepairPreflightTarget]

    private enum CodingKeys: String, CodingKey {
        case actions
        case ssotIdentity
        case absoluteLinkTarget
        case expectedOldConfigured
        case desiredConfigured
        case repairTargets
    }

    init(
        actions: [DistributionPreflightAction],
        ssotIdentity: Data,
        absoluteLinkTarget: String,
        expectedOldConfigured: Bool,
        desiredConfigured: Bool,
        repairTargets: [DistributionRepairPreflightTarget] = []
    ) {
        self.actions = actions
        self.ssotIdentity = ssotIdentity
        self.absoluteLinkTarget = absoluteLinkTarget
        self.expectedOldConfigured = expectedOldConfigured
        self.desiredConfigured = desiredConfigured
        self.repairTargets = repairTargets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decode([DistributionPreflightAction].self, forKey: .actions)
        ssotIdentity = try container.decode(Data.self, forKey: .ssotIdentity)
        absoluteLinkTarget = try container.decode(String.self, forKey: .absoluteLinkTarget)
        expectedOldConfigured = try container.decode(Bool.self, forKey: .expectedOldConfigured)
        desiredConfigured = try container.decode(Bool.self, forKey: .desiredConfigured)
        repairTargets = try container.decodeIfPresent(
            [DistributionRepairPreflightTarget].self,
            forKey: .repairTargets
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actions, forKey: .actions)
        try container.encode(ssotIdentity, forKey: .ssotIdentity)
        try container.encode(absoluteLinkTarget, forKey: .absoluteLinkTarget)
        try container.encode(expectedOldConfigured, forKey: .expectedOldConfigured)
        try container.encode(desiredConfigured, forKey: .desiredConfigured)
        if !repairTargets.isEmpty {
            try container.encode(repairTargets, forKey: .repairTargets)
        }
    }
}

private nonisolated struct DistributionRuntimeEvidence: Codable {
    struct Pending: Codable {
        let actionIndex: Int
        let kind: String
        let rootIdentity: Data
        let entryIdentity: Data?
        let absoluteLinkTarget: String
        let temporaryName: String?
    }

    struct OldOwnership: Codable {
        let targetScopeKey: String
        let appliedOperationID: Data
        let rootIdentity: Data
        let entryIdentity: Data
        let absoluteLinkTarget: String
        let verifiedAtMilliseconds: Int64
    }

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
    var oldOwnership: [OldOwnership] = []
    var pending: [Pending] = []

    private enum CodingKeys: String, CodingKey {
        case created
        case removed
        case oldOwnership
        case pending
    }

    init(
        created: [Created] = [],
        removed: [Removed] = [],
        oldOwnership: [OldOwnership] = [],
        pending: [Pending] = []
    ) {
        self.created = created
        self.removed = removed
        self.oldOwnership = oldOwnership
        self.pending = pending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decode([Created].self, forKey: .created)
        removed = try container.decode([Removed].self, forKey: .removed)
        oldOwnership = try container.decodeIfPresent(
            [OldOwnership].self,
            forKey: .oldOwnership
        ) ?? []
        pending = try container.decodeIfPresent([Pending].self, forKey: .pending) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(created, forKey: .created)
        try container.encode(removed, forKey: .removed)
        if !oldOwnership.isEmpty {
            try container.encode(oldOwnership, forKey: .oldOwnership)
        }
        if !pending.isEmpty {
            try container.encode(pending, forKey: .pending)
        }
    }
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
    private enum RecoveryExpectation: Equatable {
        case old
        case new
    }

    private enum RollbackItem {
        case created(DistributionRuntimeEvidence.Created)
        case removed(DistributionRuntimeEvidence.Removed)
    }

    private enum PendingResolution {
        case created(DistributionRuntimeEvidence.Created)
        case removed(DistributionRuntimeEvidence.Removed)
    }
    private let bindingStore: DistributionBindingStore
    private let configurationStore: DistributionConfigurationStore
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
        configurationStore = DistributionConfigurationStore(connection: connection)
        ownershipStore = DistributionLinkOwnershipStore(connection: connection)
        operationStore = try DistributionOperationStore(connection: connection)
        self.fileSystem = fileSystem
        self.nowMilliseconds = nowMilliseconds
    }

    func dryRun(
        skillID: SkillID,
        currentBindings: [DistributionBinding],
        desiredScope: DistributionDesiredScope,
        desiredConfigured: Bool = true,
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
            currentConfigured: try configurationStore.load(skillID: skillID),
            desiredScope: desiredScope,
            desiredConfigured: desiredConfigured,
            requiredAdapterCodes: requiredAdapterCodes,
            observations: observations,
            catalog: catalog
        )
    }

    func repairPlan(
        skillID: SkillID,
        selection: DistributionSelectionReadback,
        intent: DistributionRepairIntent,
        scopeKeys: Set<String>,
        catalog: DistributionTargetCatalog = .current
    ) throws -> DistributionPlan {
        let ownership = try ownershipStore.load(skillID: skillID)
        var observations: [DistributionTargetEntry: DistributionTargetObservation] = [:]
        for binding in selection.bindings {
            guard let entry = catalog.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ) else {
                throw DistributionRepairPlanningError.unavailable
            }
            observations[entry] = try observe(
                entry: entry,
                skillID: skillID,
                ownership: ownership
            )
        }
        return try DistributionPlanner().repairPlan(
            skillID: skillID,
            selection: selection,
            intent: intent,
            scopeKeys: scopeKeys,
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
        guard (plan.repairIntent == nil) == plan.repairScopeKeys.isEmpty else {
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

        let operationID = SSOTOperationID()
        let preflight = try makePreflight(
            skillID: skillID,
            plan: plan,
            expectedOldBindings: expectedOldBindings,
            expectedOldOwnership: expectedOldOwnership,
            operationID: operationID
        )
        let runtime = try runtimePayload(
            created: [:],
            quarantined: [:],
            oldOwnership: expectedOldOwnership
        )
        let draft = try DistributionOperationDraft(
            operationID: operationID,
            skillID: skillID,
            oldBindings: try DistributionOperationPayloadCodec.encode(
                expectedOldBindings.map(DistributionBindingPayload.init)
            ),
            newBindings: try DistributionOperationPayloadCodec.encode(
                plan.bindingReplacement.map(DistributionBindingPayload.init)
            ),
            planPayload: try plan.canonicalJSONData(),
            preflightPayload: try DistributionOperationPayloadCodec.encode(preflight),
            runtimePayload: runtime,
            createdAtMilliseconds: timestamp
        )
        _ = try operationStore.transaction {
            try operationStore.insertPrepared(draft)
        }
        var record = try operationStore.load(operationID)
        var quarantined: [Int: DistributionQuarantinedSymlink] = [:]
        var created: [Int: DistributionSymlinkEvidence] = [:]
        var pending: [Int: DistributionRuntimeEvidence.Pending] = [:]
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
                    pending[index] = DistributionRuntimeEvidence.Pending(
                        actionIndex: index,
                        kind: action.kind.rawValue,
                        rootIdentity: try ManagedItemIdentityCodec.encode(ownership.rootIdentity),
                        entryIdentity: try ManagedItemIdentityCodec.encode(ownership.entryIdentity),
                        absoluteLinkTarget: ownership.absoluteLinkTarget,
                        temporaryName: DistributionSymlinkFileSystem.temporaryName(
                            operationID: operationID.uuid,
                            actionIndex: index
                        )
                    )
                    try operationStore.updateProgress(
                        operationID: operationID,
                        phase: .applying,
                        forwardCursor: Int64(index),
                        rollbackCursor: 0,
                        cleanupCursor: 0,
                        runtimePayload: try runtimePayload(
                            created: created,
                            quarantined: quarantined,
                            pending: pending,
                            oldOwnership: expectedOldOwnership
                        ),
                        attemptCount: record.attemptCount + 1,
                        lastError: nil,
                        updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
                    )
                    quarantined[index] = try fileSystem.quarantine(
                        action.entry,
                        expected: evidence,
                        operationID: operationID.uuid,
                        actionIndex: index
                    )
                case .createSymlink:
                    guard let preflightAction = preflight.actions[safe: index],
                          let expectedSSOTIdentity = try? ManagedItemIdentityCodec.decode(
                              preflightAction.ssotIdentity
                          ),
                          let ssot = try? fileSystem.ssotEvidence(for: skillID),
                          ssot.identity == expectedSSOTIdentity,
                          ssot.absoluteTarget == preflightAction.absoluteLinkTarget
                    else {
                        throw DistributionSymlinkExecutorError.needsRepair("SSOT identity changed")
                    }
                    let rootIdentity = try fileSystem.ensureRoot(for: action.entry.target.scope)
                    if !preflightAction.rootIdentity.isEmpty {
                        guard try ManagedItemIdentityCodec.decode(
                            preflightAction.rootIdentity
                        ) == rootIdentity else {
                            throw DistributionSymlinkExecutorError.conflict
                        }
                    }
                    pending[index] = DistributionRuntimeEvidence.Pending(
                        actionIndex: index,
                        kind: action.kind.rawValue,
                        rootIdentity: try ManagedItemIdentityCodec.encode(rootIdentity),
                        entryIdentity: nil,
                        absoluteLinkTarget: preflightAction.absoluteLinkTarget,
                        temporaryName: nil
                    )
                    try operationStore.updateProgress(
                        operationID: operationID,
                        phase: .applying,
                        forwardCursor: Int64(index),
                        rollbackCursor: 0,
                        cleanupCursor: 0,
                        runtimePayload: try runtimePayload(
                            created: created,
                            quarantined: quarantined,
                            pending: pending,
                            oldOwnership: expectedOldOwnership
                        ),
                        attemptCount: record.attemptCount + 1,
                        lastError: nil,
                        updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
                    )
                    let evidence = try fileSystem.create(
                        action.entry,
                        absoluteTarget: preflightAction.absoluteLinkTarget,
                        expectedRootIdentity: rootIdentity
                    )
                    created[index] = evidence
                case .createCopy, .refreshCopy, .discardCopyDrift, .removeCopy,
                     .replaceSymlinkWithCopy, .replaceCopyWithSymlink:
                    throw DistributionSymlinkExecutorError.conflict
                }
                pending[index] = nil
                try operationStore.updateProgress(
                    operationID: operationID,
                    phase: .applying,
                    forwardCursor: Int64(index + 1),
                    rollbackCursor: 0,
                    cleanupCursor: 0,
                    runtimePayload: try runtimePayload(
                        created: created,
                        quarantined: quarantined,
                        pending: pending,
                        oldOwnership: expectedOldOwnership
                    ),
                    attemptCount: Int64(index + 2),
                    lastError: nil,
                    updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
                )
                record = try operationStore.load(operationID)
            }
            let desiredOwnership = try makeDesiredOwnership(
                skillID: skillID,
                plan: plan,
                oldOwnership: expectedOldOwnership,
                created: created,
                operationID: operationID,
                timestamp: timestamp
            )
            guard try finalReadback(
                skillID: skillID,
                bindings: plan.bindingReplacement,
                ownership: desiredOwnership,
                expectedSSOTIdentity: try expectedSSOTIdentity(from: preflight),
                allowedMissingScopeKeys: repairRemainingMissingScopeKeys(
                    intent: plan.repairIntent,
                    selectedScopeKeys: plan.repairScopeKeys,
                    preflight: preflight
                )
            ), try repairTargetsMatchAppliedState(plan: plan, preflight: preflight) else {
                throw DistributionSymlinkExecutorError.needsRepair("filesystem readback drifted")
            }
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .filesystemApplied,
                forwardCursor: Int64(plan.filesystemActions.count),
                rollbackCursor: 0,
                cleanupCursor: 0,
                runtimePayload: try runtimePayload(
                    created: created,
                    quarantined: quarantined,
                    pending: pending,
                    oldOwnership: expectedOldOwnership
                ),
                attemptCount: record.attemptCount + 1,
                lastError: nil,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )

            try operationStore.transaction {
                try replaceDatabaseState(
                    skillID: skillID,
                    expectedOldBindings: expectedOldBindings,
                    expectedOldOwnership: expectedOldOwnership,
                    desiredBindings: plan.bindingReplacement,
                    desiredOwnership: desiredOwnership,
                    expectedOldConfigured: plan.expectedOldConfigured,
                    desiredConfigured: plan.desiredConfigured,
                    operationID: operationID,
                    nowMilliseconds: timestamp
                )
                try operationStore.updateProgress(
                    operationID: operationID,
                    phase: .databaseCommitted,
                    forwardCursor: Int64(plan.filesystemActions.count),
                    rollbackCursor: 0,
                    cleanupCursor: 0,
                    runtimePayload: try runtimePayload(
                        created: created,
                        quarantined: quarantined,
                        pending: pending,
                        oldOwnership: expectedOldOwnership
                    ),
                    attemptCount: record.attemptCount + 2,
                    lastError: nil,
                    updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
                )
            }
            record = try operationStore.load(operationID)
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .cleaning,
                forwardCursor: Int64(plan.filesystemActions.count),
                rollbackCursor: 0,
                cleanupCursor: 0,
                runtimePayload: try runtimePayload(
                    created: created,
                    quarantined: quarantined,
                    pending: pending,
                    oldOwnership: expectedOldOwnership
                ),
                attemptCount: record.attemptCount + 1,
                lastError: nil,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )
            for (cleanupIndex, pair) in quarantined.sorted(by: { $0.key < $1.key }).enumerated() {
                let (index, item) = pair
                try fileSystem.cleanup(plan.filesystemActions[index].entry, quarantined: item)
                try operationStore.updateProgress(
                    operationID: operationID,
                    phase: .cleaning,
                    forwardCursor: Int64(plan.filesystemActions.count),
                    rollbackCursor: 0,
                    cleanupCursor: Int64(cleanupIndex + 1),
                    runtimePayload: try runtimePayload(
                        created: created,
                        quarantined: quarantined,
                        pending: pending,
                        oldOwnership: expectedOldOwnership
                    ),
                    attemptCount: record.attemptCount + Int64(cleanupIndex + 2),
                    lastError: nil,
                    updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
                )
            }
            guard try finalReadback(
                skillID: skillID,
                bindings: plan.bindingReplacement,
                ownership: desiredOwnership,
                expectedSSOTIdentity: try expectedSSOTIdentity(from: preflight),
                allowedMissingScopeKeys: repairRemainingMissingScopeKeys(
                    intent: plan.repairIntent,
                    selectedScopeKeys: plan.repairScopeKeys,
                    preflight: preflight
                )
            ), try repairTargetsMatchAppliedState(plan: plan, preflight: preflight) else {
                throw DistributionSymlinkExecutorError.needsRepair("final distribution readback drifted")
            }
            try operationStore.complete(
                operationID: operationID,
                outcome: .applied,
                updatedAtMilliseconds: max(timestamp, record.updatedAtMilliseconds)
            )
            return try operationStore.load(operationID)
        } catch {
            do {
                if let current = try? operationStore.load(operationID),
                   current.phase != .databaseCommitted,
                   current.phase != .cleaning {
                    try operationStore.updateProgress(
                        operationID: operationID,
                        phase: .rollingBack,
                        forwardCursor: current.forwardCursor,
                        rollbackCursor: 0,
                        cleanupCursor: 0,
                        runtimePayload: try runtimePayload(
                            created: created,
                            quarantined: quarantined,
                            pending: pending,
                            oldOwnership: expectedOldOwnership
                        ),
                        attemptCount: current.attemptCount + 1,
                        lastError: error.localizedDescription,
                        updatedAtMilliseconds: max(timestamp, current.updatedAtMilliseconds)
                    )
                }
                if let current = try? operationStore.load(operationID),
                   current.phase != .databaseCommitted,
                   current.phase != .cleaning {
                    try rollback(
                        operationID: operationID,
                        plan: plan,
                        created: created,
                        quarantined: quarantined,
                        pending: pending,
                        record: current,
                        expectedOldOwnership: expectedOldOwnership,
                        error: error,
                        timestamp: timestamp
                    )
                    try verifyRollback(
                        skillID: skillID,
                        plan: plan,
                        expectedOldOwnership: expectedOldOwnership
                    )
                    try operationStore.complete(
                        operationID: operationID,
                        outcome: .rolledBack,
                        updatedAtMilliseconds: max(timestamp, current.updatedAtMilliseconds)
                    )
                } else {
                    try operationStore.markNeedsRepair(
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
            guard operation.formatVersion == 1 else { continue }
            if operation.phase == .prepared {
                let runtime = try decodeRuntime(operation)
                if runtime.created.isEmpty && runtime.removed.isEmpty {
                    guard try databaseMatches(operation: operation, expected: .old),
                          try diskMatches(operation: operation, expected: .old) else {
                        try operationStore.markNeedsRepair(
                            operationID: operation.operationID,
                            detail: "prepared operation is not the complete old state",
                            updatedAtMilliseconds: max(
                                operation.updatedAtMilliseconds,
                                nowMilliseconds()
                            )
                        )
                        continue
                    }
                    try operationStore.updateProgress(
                        operationID: operation.operationID,
                        phase: .rollingBack,
                        forwardCursor: 0,
                        rollbackCursor: 0,
                        cleanupCursor: 0,
                        runtimePayload: operation.runtimePayload,
                        attemptCount: operation.attemptCount + 1,
                        lastError: nil,
                        updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
                    )
                    try operationStore.complete(
                        operationID: operation.operationID,
                        outcome: .rolledBack,
                        updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
                    )
                } else {
                    try operationStore.markNeedsRepair(
                        operationID: operation.operationID,
                        detail: "prepared operation contains filesystem evidence",
                        updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
                    )
                }
            } else if operation.phase == .applying || operation.phase == .rollingBack {
                do {
                    guard try databaseMatches(operation: operation, expected: .old) else {
                        throw DistributionSymlinkExecutorError.needsRepair(
                            "rollback database snapshot is not complete old state"
                        )
                    }
                    try recoverRollback(operation)
                    guard try databaseMatches(operation: operation, expected: .old),
                          try diskMatches(operation: operation, expected: .old) else {
                        throw DistributionSymlinkExecutorError.needsRepair(
                            "rollback readback is not the complete old state"
                        )
                    }
                    try operationStore.complete(
                        operationID: operation.operationID,
                        outcome: .rolledBack,
                        updatedAtMilliseconds: max(
                            operation.updatedAtMilliseconds,
                            nowMilliseconds()
                        )
                    )
                } catch {
                    try operationStore.markNeedsRepair(
                        operationID: operation.operationID,
                        detail: error.localizedDescription,
                        updatedAtMilliseconds: max(
                            operation.updatedAtMilliseconds,
                            nowMilliseconds()
                        )
                    )
                }
            } else if operation.phase == .filesystemApplied {
                do {
                    try recoverFilesystemApplied(operation)
                    try operationStore.updateProgress(
                        operationID: operation.operationID,
                        phase: .cleaning,
                        forwardCursor: operation.forwardCursor,
                        rollbackCursor: operation.rollbackCursor,
                        cleanupCursor: operation.cleanupCursor,
                        runtimePayload: operation.runtimePayload,
                        attemptCount: operation.attemptCount + 1,
                        lastError: nil,
                        updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
                    )
                    let cleaning = try operationStore.load(operation.operationID)
                    try recoverCleanup(cleaning)
                    guard try diskMatches(
                        operation: cleaning,
                        expected: .new
                    ) else {
                        throw DistributionSymlinkExecutorError.needsRepair(
                            "filesystem readback is not the complete new state"
                        )
                    }
                    try operationStore.complete(
                        operationID: operation.operationID,
                        outcome: .applied,
                        updatedAtMilliseconds: max(cleaning.updatedAtMilliseconds, nowMilliseconds())
                    )
                } catch {
                    try operationStore.markNeedsRepair(
                        operationID: operation.operationID,
                        detail: error.localizedDescription,
                        updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
                    )
                }
            } else if operation.phase == .databaseCommitted || operation.phase == .cleaning {
                do {
                    if operation.phase == .databaseCommitted {
                        try operationStore.updateProgress(
                            operationID: operation.operationID,
                            phase: .cleaning,
                            forwardCursor: operation.forwardCursor,
                            rollbackCursor: operation.rollbackCursor,
                            cleanupCursor: operation.cleanupCursor,
                            runtimePayload: operation.runtimePayload,
                            attemptCount: operation.attemptCount + 1,
                            lastError: nil,
                            updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
                        )
                    }
                    let cleaning = try operationStore.load(operation.operationID)
                    guard try databaseMatches(
                        operation: cleaning,
                        expected: .new
                    ) else {
                        throw DistributionSymlinkExecutorError.needsRepair(
                            "database snapshot is not the complete new state"
                        )
                    }
                    try recoverCleanup(cleaning)
                    guard try diskMatches(
                        operation: cleaning,
                        expected: .new
                    ) else {
                        throw DistributionSymlinkExecutorError.needsRepair(
                            "filesystem readback is not the complete new state"
                        )
                    }
                    try operationStore.complete(
                        operationID: operation.operationID,
                        outcome: .applied,
                        updatedAtMilliseconds: max(
                            cleaning.updatedAtMilliseconds,
                            nowMilliseconds()
                        )
                    )
                } catch {
                    try operationStore.markNeedsRepair(
                        operationID: operation.operationID,
                        detail: error.localizedDescription,
                        updatedAtMilliseconds: max(
                            operation.updatedAtMilliseconds,
                            nowMilliseconds()
                        )
                    )
                }
            } else {
                try operationStore.markNeedsRepair(
                    operationID: operation.operationID,
                    detail: "recovery evidence requires explicit repair",
                    updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
                )
            }
        }
    }

    private func recoverRollback(_ operation: DistributionOperationRecord) throws {
        guard try currentSSOTMatches(operation) else {
            throw DistributionSymlinkExecutorError.needsRepair("SSOT identity changed")
        }
        let preflight = try decodePreflight(operation).actions
        var runtime = try DistributionOperationPayloadCodec.decode(
            DistributionRuntimeEvidence.self,
            from: operation.runtimePayload
        )
        for pending in runtime.pending.sorted(by: { $0.actionIndex > $1.actionIndex }) {
            switch try reconcilePending(pending, preflight: preflight) {
            case .created(let evidence):
                runtime.created.append(evidence)
            case .removed(let evidence):
                runtime.removed.append(evidence)
            }
            runtime.pending.removeAll { $0.actionIndex == pending.actionIndex }
            let current = try operationStore.load(operation.operationID)
            try operationStore.updateProgress(
                operationID: operation.operationID,
                phase: .rollingBack,
                forwardCursor: max(current.forwardCursor, Int64(pending.actionIndex + 1)),
                rollbackCursor: current.rollbackCursor,
                cleanupCursor: current.cleanupCursor,
                runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
                attemptCount: current.attemptCount + 1,
                lastError: current.lastError,
                updatedAtMilliseconds: max(current.updatedAtMilliseconds, nowMilliseconds())
            )
        }
        let items = rollbackItems(runtime)
        let currentRollbackCursor = try operationStore.load(operation.operationID).rollbackCursor
        guard currentRollbackCursor <= Int64(items.count) else {
            throw DistributionSymlinkExecutorError.needsRepair("rollback cursor exceeds evidence")
        }
        if try operationStore.load(operation.operationID).phase == .applying {
            let current = try operationStore.load(operation.operationID)
            try operationStore.updateProgress(
                operationID: operation.operationID,
                phase: .rollingBack,
                forwardCursor: current.forwardCursor,
                rollbackCursor: current.rollbackCursor,
                cleanupCursor: 0,
                runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
                attemptCount: operation.attemptCount + 1,
                lastError: operation.lastError,
                updatedAtMilliseconds: max(operation.updatedAtMilliseconds, nowMilliseconds())
            )
        }
        var rollbackCursor = try operationStore.load(operation.operationID).rollbackCursor
        for item in items.dropFirst(Int(rollbackCursor)) {
            switch item {
            case .created(let created):
            guard let action = preflight[safe: created.actionIndex],
                  let entry = preflightEntry(action) else {
                throw DistributionSymlinkExecutorError.needsRepair("invalid rollback action")
            }
            try fileSystem.removeCreated(
                entry,
                expected: DistributionSymlinkEvidence(
                    rootIdentity: try ManagedItemIdentityCodec.decode(created.rootIdentity),
                    entryIdentity: try ManagedItemIdentityCodec.decode(created.entryIdentity),
                    absoluteTarget: created.absoluteLinkTarget
                )
            )
            case .removed(let removed):
            guard let action = preflight[safe: removed.actionIndex],
                  let entry = preflightEntry(action) else {
                throw DistributionSymlinkExecutorError.needsRepair("invalid restore action")
            }
            try fileSystem.restore(
                entry,
                quarantined: DistributionQuarantinedSymlink(
                    temporaryName: removed.temporaryName,
                    evidence: DistributionSymlinkEvidence(
                        rootIdentity: try ManagedItemIdentityCodec.decode(removed.rootIdentity),
                        entryIdentity: try ManagedItemIdentityCodec.decode(removed.entryIdentity),
                        absoluteTarget: removed.absoluteLinkTarget
                    )
                )
            )
            }
            let current = try operationStore.load(operation.operationID)
            rollbackCursor = current.rollbackCursor + 1
            try operationStore.updateProgress(
                operationID: operation.operationID,
                phase: .rollingBack,
                forwardCursor: current.forwardCursor,
                rollbackCursor: rollbackCursor,
                cleanupCursor: 0,
                runtimePayload: try DistributionOperationPayloadCodec.encode(runtime),
                attemptCount: current.attemptCount + 1,
                lastError: current.lastError,
                updatedAtMilliseconds: max(current.updatedAtMilliseconds, nowMilliseconds())
            )
        }
    }

    private func recoverCleanup(_ operation: DistributionOperationRecord) throws {
        guard try currentSSOTMatches(operation) else {
            throw DistributionSymlinkExecutorError.needsRepair("SSOT identity changed")
        }
        let preflight = try decodePreflight(operation).actions
        let runtime = try DistributionOperationPayloadCodec.decode(
            DistributionRuntimeEvidence.self,
            from: operation.runtimePayload
        )
        guard operation.cleanupCursor <= Int64(runtime.removed.count) else {
            throw DistributionSymlinkExecutorError.needsRepair("cleanup cursor exceeds evidence")
        }
        for removed in runtime.removed.dropFirst(Int(operation.cleanupCursor)) {
            guard let action = preflight[safe: removed.actionIndex],
                  let entry = preflightEntry(action) else {
                throw DistributionSymlinkExecutorError.needsRepair("invalid cleanup action")
            }
            try fileSystem.cleanup(
                entry,
                quarantined: DistributionQuarantinedSymlink(
                    temporaryName: removed.temporaryName,
                    evidence: DistributionSymlinkEvidence(
                        rootIdentity: try ManagedItemIdentityCodec.decode(removed.rootIdentity),
                        entryIdentity: try ManagedItemIdentityCodec.decode(removed.entryIdentity),
                        absoluteTarget: removed.absoluteLinkTarget
                    )
                )
            )
            let current = try operationStore.load(operation.operationID)
            try operationStore.updateProgress(
                operationID: operation.operationID,
                phase: .cleaning,
                forwardCursor: current.forwardCursor,
                rollbackCursor: current.rollbackCursor,
                cleanupCursor: current.cleanupCursor + 1,
                runtimePayload: operation.runtimePayload,
                attemptCount: current.attemptCount + 1,
                lastError: current.lastError,
                updatedAtMilliseconds: max(current.updatedAtMilliseconds, nowMilliseconds())
            )
        }
    }

    private func reconcilePending(
        _ pending: DistributionRuntimeEvidence.Pending,
        preflight: [DistributionPreflightAction]
    ) throws -> PendingResolution {
        guard let action = preflight[safe: pending.actionIndex],
              let entry = preflightEntry(action),
              action.kind == pending.kind else {
            throw DistributionSymlinkExecutorError.needsRepair("invalid pending action")
        }
        let rootIdentity = try ManagedItemIdentityCodec.decode(pending.rootIdentity)
        switch action.kind {
        case DistributionFilesystemActionKind.createSymlink.rawValue:
            switch try fileSystem.observe(entry) {
            case .missing(let observedRoot) where observedRoot == rootIdentity:
                // A missing target with the same root proves the create syscall did not
                // materialize. Record synthetic evidence so the journal can advance and
                // rollback remains idempotent if the target appears before cleanup.
                return .created(
                    DistributionRuntimeEvidence.Created(
                        actionIndex: pending.actionIndex,
                        rootIdentity: pending.rootIdentity,
                        entryIdentity: pending.rootIdentity,
                        absoluteLinkTarget: pending.absoluteLinkTarget
                    )
                )
            case .missing:
                throw DistributionSymlinkExecutorError.needsRepair(
                    "pending create action was not materialized"
                )
            case .symlink(let root, let identity, let target)
                where root == rootIdentity && target == pending.absoluteLinkTarget:
                try fileSystem.removeCreated(
                    entry,
                    expected: DistributionSymlinkEvidence(
                        rootIdentity: root,
                        entryIdentity: identity,
                        absoluteTarget: target
                    )
                )
                return .created(
                    DistributionRuntimeEvidence.Created(
                        actionIndex: pending.actionIndex,
                        rootIdentity: pending.rootIdentity,
                        entryIdentity: try ManagedItemIdentityCodec.encode(identity),
                        absoluteLinkTarget: target
                    )
                )
            default:
                throw DistributionSymlinkExecutorError.needsRepair(
                    "pending create action changed on disk"
                )
            }
        case DistributionFilesystemActionKind.removeSymlink.rawValue:
            guard let entryIdentity = pending.entryIdentity,
                  let temporaryName = pending.temporaryName else {
                throw DistributionSymlinkExecutorError.needsRepair("invalid pending remove action")
            }
            try fileSystem.restore(
                entry,
                quarantined: DistributionQuarantinedSymlink(
                    temporaryName: temporaryName,
                    evidence: DistributionSymlinkEvidence(
                        rootIdentity: rootIdentity,
                        entryIdentity: try ManagedItemIdentityCodec.decode(entryIdentity),
                        absoluteTarget: pending.absoluteLinkTarget
                    )
                )
            )
            return .removed(
                DistributionRuntimeEvidence.Removed(
                    actionIndex: pending.actionIndex,
                    temporaryName: temporaryName,
                    rootIdentity: pending.rootIdentity,
                    entryIdentity: entryIdentity,
                    absoluteLinkTarget: pending.absoluteLinkTarget
                )
            )
        default:
            throw DistributionSymlinkExecutorError.needsRepair("unsupported pending action")
        }
    }

    private func recoverFilesystemApplied(
        _ operation: DistributionOperationRecord
    ) throws {
        guard try databaseMatches(operation: operation, expected: .old) else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "filesystemApplied operation has a non-old database snapshot"
            )
        }
        let preflight = try decodePreflight(operation)
        let runtime = try decodeRuntime(operation)
        let newBindings = try decodeBindingIntents(operation.newBindings, skillID: operation.skillID)
        let plan = try recoveryPlan(
            operation: operation,
            bindings: newBindings,
            preflight: preflight
        )
        let expectedOldBindings = try decodeBindings(
            operation.oldBindings,
            skillID: operation.skillID
        )
        let oldOwnership = try expectedOwnership(
            operation: operation,
            bindings: expectedOldBindings.map(\.intent),
            expectation: .old
        )
        let desiredOwnership = try makeDesiredOwnership(
            skillID: operation.skillID,
            plan: plan,
            oldOwnership: oldOwnership,
            created: Dictionary(
                uniqueKeysWithValues: runtime.created.map {
                    ($0.actionIndex, DistributionSymlinkEvidence(
                        rootIdentity: try ManagedItemIdentityCodec.decode($0.rootIdentity),
                        entryIdentity: try ManagedItemIdentityCodec.decode($0.entryIdentity),
                        absoluteTarget: $0.absoluteLinkTarget
                    ))
                }
            ),
            operationID: operation.operationID,
            timestamp: operation.createdAtMilliseconds
        )
        guard try finalReadback(
            skillID: operation.skillID,
            bindings: newBindings,
            ownership: desiredOwnership,
            expectedSSOTIdentity: try expectedSSOTIdentity(from: preflight),
            allowedMissingScopeKeys: repairRemainingMissingScopeKeys(
                intent: plan.repairIntent,
                selectedScopeKeys: plan.repairScopeKeys,
                preflight: preflight
            )
        ), try repairTargetsMatchAppliedState(plan: plan, preflight: preflight) else {
            throw DistributionSymlinkExecutorError.needsRepair(
                "filesystemApplied readback drifted"
            )
        }
        try operationStore.transaction {
            try replaceDatabaseState(
                skillID: operation.skillID,
                expectedOldBindings: expectedOldBindings,
                expectedOldOwnership: oldOwnership,
                desiredBindings: newBindings,
                desiredOwnership: desiredOwnership,
                expectedOldConfigured: preflight.expectedOldConfigured,
                desiredConfigured: preflight.desiredConfigured,
                operationID: operation.operationID,
                nowMilliseconds: operation.createdAtMilliseconds
            )
            let current = try operationStore.load(operation.operationID)
            try operationStore.updateProgress(
                operationID: operation.operationID,
                phase: .databaseCommitted,
                forwardCursor: current.forwardCursor,
                rollbackCursor: current.rollbackCursor,
                cleanupCursor: current.cleanupCursor,
                runtimePayload: current.runtimePayload,
                attemptCount: current.attemptCount + 1,
                lastError: nil,
                updatedAtMilliseconds: max(
                    current.updatedAtMilliseconds,
                    operation.createdAtMilliseconds
                )
            )
        }
    }

    private func replaceDatabaseState(
        skillID: SkillID,
        expectedOldBindings: [DistributionBinding],
        expectedOldOwnership: [DistributionLinkOwnership],
        desiredBindings: [DistributionBindingIntent],
        desiredOwnership: [DistributionLinkOwnership],
        expectedOldConfigured: Bool,
        desiredConfigured: Bool,
        operationID: SSOTOperationID,
        nowMilliseconds: Int64
    ) throws {
        _ = try ownershipStore.replaceInCurrentTransaction(
            skillID: skillID,
            expectedOld: expectedOldOwnership,
            desired: [],
            appliedOperationID: operationID,
            nowMilliseconds: nowMilliseconds
        )
        _ = try bindingStore.replaceInCurrentTransaction(
            skillID: skillID,
            expectedOld: expectedOldBindings,
            desired: desiredBindings,
            nowMilliseconds: nowMilliseconds
        )
        try configurationStore.replaceInCurrentTransaction(
            skillID: skillID,
            expectedOld: expectedOldConfigured,
            desired: desiredConfigured,
            nowMilliseconds: nowMilliseconds
        )
        _ = try ownershipStore.replaceInCurrentTransaction(
            skillID: skillID,
            expectedOld: [],
            desired: desiredOwnership,
            appliedOperationID: operationID,
            nowMilliseconds: nowMilliseconds,
            retainedOld: expectedOldOwnership
        )
    }

    private func decodeRuntime(
        _ operation: DistributionOperationRecord
    ) throws -> DistributionRuntimeEvidence {
        try DistributionOperationPayloadCodec.decode(
            DistributionRuntimeEvidence.self,
            from: operation.runtimePayload
        )
    }

    private func decodePreflight(
        _ operation: DistributionOperationRecord
    ) throws -> DistributionPreflightPayload {
        if let payload = try? DistributionOperationPayloadCodec.decode(
            DistributionPreflightPayload.self,
            from: operation.preflightPayload
        ) {
            return payload
        }
        let actions = try DistributionOperationPayloadCodec.decode(
            [DistributionPreflightAction].self,
            from: operation.preflightPayload
        )
        guard let first = actions.first else {
            return DistributionPreflightPayload(
                actions: [],
                ssotIdentity: Data(),
                absoluteLinkTarget: "",
                expectedOldConfigured: try !decodeBindings(
                    operation.oldBindings,
                    skillID: operation.skillID
                ).isEmpty,
                desiredConfigured: true
            )
        }
        return DistributionPreflightPayload(
            actions: actions,
            ssotIdentity: first.ssotIdentity,
            absoluteLinkTarget: first.absoluteLinkTarget,
            expectedOldConfigured: try !decodeBindings(
                operation.oldBindings,
                skillID: operation.skillID
            ).isEmpty,
            desiredConfigured: true
        )
    }

    private func rollbackItems(
        _ runtime: DistributionRuntimeEvidence
    ) -> [RollbackItem] {
        runtime.created
            .sorted { $0.actionIndex > $1.actionIndex }
            .map(RollbackItem.created)
        + runtime.removed
            .sorted { $0.actionIndex > $1.actionIndex }
            .map(RollbackItem.removed)
    }

    private func rollback(
        operationID: SSOTOperationID,
        plan: DistributionPlan,
        created: [Int: DistributionSymlinkEvidence],
        quarantined: [Int: DistributionQuarantinedSymlink],
        pending: [Int: DistributionRuntimeEvidence.Pending] = [:],
        record: DistributionOperationRecord,
        expectedOldOwnership: [DistributionLinkOwnership],
        error: Error,
        timestamp: Int64
    ) throws {
        let runtime = try DistributionOperationPayloadCodec.decode(
            DistributionRuntimeEvidence.self,
            from: try runtimePayload(
                        created: created,
                        quarantined: quarantined,
                        pending: pending,
                        oldOwnership: expectedOldOwnership
            )
        )
        let items = rollbackItems(runtime)
        guard record.rollbackCursor <= Int64(items.count) else {
            throw DistributionSymlinkExecutorError.needsRepair("rollback cursor exceeds evidence")
        }
        var current = record
        if current.phase != .rollingBack {
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .rollingBack,
                forwardCursor: current.forwardCursor,
                rollbackCursor: current.rollbackCursor,
                cleanupCursor: 0,
                runtimePayload: try runtimePayload(
                        created: created,
                        quarantined: quarantined,
                        pending: pending,
                        oldOwnership: expectedOldOwnership
                ),
                attemptCount: current.attemptCount + 1,
                lastError: error.localizedDescription,
                updatedAtMilliseconds: max(timestamp, current.updatedAtMilliseconds)
            )
            current = try operationStore.load(operationID)
        }
        for item in items.dropFirst(Int(current.rollbackCursor)) {
            switch item {
            case .created(let evidence):
                guard let action = plan.filesystemActions[safe: evidence.actionIndex] else {
                    throw DistributionSymlinkExecutorError.needsRepair("invalid rollback action")
                }
                guard let expected = created[evidence.actionIndex] else {
                    throw DistributionSymlinkExecutorError.needsRepair("missing created evidence")
                }
                try fileSystem.removeCreated(action.entry, expected: expected)
            case .removed(let evidence):
                guard let action = plan.filesystemActions[safe: evidence.actionIndex],
                      let quarantined = quarantined[evidence.actionIndex] else {
                    throw DistributionSymlinkExecutorError.needsRepair("missing removed evidence")
                }
                try fileSystem.restore(action.entry, quarantined: quarantined)
            }
            current = try operationStore.load(operationID)
            try operationStore.updateProgress(
                operationID: operationID,
                phase: .rollingBack,
                forwardCursor: current.forwardCursor,
                rollbackCursor: current.rollbackCursor + 1,
                cleanupCursor: 0,
                runtimePayload: try runtimePayload(
                    created: created,
                    quarantined: quarantined,
                    pending: pending,
                    oldOwnership: expectedOldOwnership
                ),
                attemptCount: current.attemptCount + 1,
                lastError: error.localizedDescription,
                updatedAtMilliseconds: max(timestamp, current.updatedAtMilliseconds)
            )
        }
    }

    private func verifyRollback(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldOwnership: [DistributionLinkOwnership]
    ) throws {
        for action in plan.filesystemActions {
            let observation = try fileSystem.observe(action.entry)
            switch action.kind {
            case .createSymlink:
                guard case .missing = observation else {
                    throw DistributionSymlinkExecutorError.needsRepair(
                        "rollback left a created link"
                    )
                }
            case .removeSymlink:
                guard let expected = expectedOldOwnership.first(where: {
                    $0.targetScopeKey == action.entry.target.scope.targetScopeKey
                }), case .symlink(let root, let entry, let target) = observation,
                      root == expected.rootIdentity,
                      entry == expected.entryIdentity,
                      target == expected.absoluteLinkTarget else {
                    throw DistributionSymlinkExecutorError.needsRepair("rollback did not restore a link")
                }
            case .createCopy, .refreshCopy, .discardCopyDrift, .removeCopy,
                 .replaceSymlinkWithCopy, .replaceCopyWithSymlink:
                throw DistributionSymlinkExecutorError.needsRepair(
                    "v1 rollback contains a Copy action"
                )
            }
        }
        guard try ownershipStore.load(skillID: skillID) == expectedOldOwnership else {
            throw DistributionSymlinkExecutorError.needsRepair("rollback ownership drifted")
        }
    }

    private func decodeBindingIntents(
        _ data: Data,
        skillID: SkillID
    ) throws -> [DistributionBindingIntent] {
        let payloads = try DistributionOperationPayloadCodec.decode(
            [DistributionBindingPayload].self,
            from: data
        )
        return try payloads.map { try $0.intent(skillID: skillID) }
    }

    private func decodeBindings(
        _ data: Data,
        skillID: SkillID
    ) throws -> [DistributionBinding] {
        let payloads = try DistributionOperationPayloadCodec.decode(
            [DistributionBindingPayload].self,
            from: data
        )
        return try payloads.map { try $0.binding(skillID: skillID) }
    }

    private func recoveryPlan(
        operation: DistributionOperationRecord,
        bindings: [DistributionBindingIntent],
        preflight: DistributionPreflightPayload
    ) throws -> DistributionPlan {
        let wire = try DistributionOperationPayloadCodec.decode(
            DistributionPlanWire.self,
            from: operation.planPayload
        )
        let actions = try preflight.actions.map { action in
            guard let entry = preflightEntry(action),
                  let kind = DistributionFilesystemActionKind(rawValue: action.kind) else {
                throw DistributionSymlinkExecutorError.needsRepair("invalid persisted plan")
            }
            return DistributionFilesystemAction(kind: kind, entry: entry, ssotLocator: action.absoluteLinkTarget)
        }
        return DistributionPlan(
            status: .executable,
            filesystemActions: actions,
            bindingsChanged: wire.bindingsChanged,
            bindingReplacement: bindings,
            configurationChanged: preflight.expectedOldConfigured
                != preflight.desiredConfigured,
            expectedOldConfigured: preflight.expectedOldConfigured,
            desiredConfigured: preflight.desiredConfigured,
            conflicts: [],
            repairIntent: wire.repairIntent.flatMap(DistributionRepairIntent.init),
            repairScopeKeys: wire.repairScopeKeys ?? []
        )
    }

    private func databaseMatches(
        operation: DistributionOperationRecord,
        expected: RecoveryExpectation
    ) throws -> Bool {
        let preflight = try decodePreflight(operation)
        let expectedConfigured = expected == .old
            ? preflight.expectedOldConfigured
            : preflight.desiredConfigured
        guard try configurationStore.load(skillID: operation.skillID)
                == expectedConfigured else {
            return false
        }
        let bindingPayload = expected == .old ? operation.oldBindings : operation.newBindings
        let expectedBindings = try decodeBindingIntents(bindingPayload, skillID: operation.skillID)
        let actualBindings = try bindingStore.load(skillID: operation.skillID).map(\.intent)
        let canonical: ([DistributionBindingIntent]) -> [DistributionBindingIntent] = {
            $0.sorted { $0.scope.targetScopeKey < $1.scope.targetScopeKey }
        }
        guard canonical(actualBindings) == canonical(expectedBindings) else { return false }
        let ownership = try ownershipStore.load(skillID: operation.skillID)
        let expectedOwnership = try expectedOwnership(
            operation: operation,
            bindings: expectedBindings,
            expectation: expected
        )
        return ownership.sorted { $0.targetScopeKey < $1.targetScopeKey }
            == expectedOwnership.sorted { $0.targetScopeKey < $1.targetScopeKey }
    }

    private func expectedOwnership(
        operation: DistributionOperationRecord,
        bindings: [DistributionBindingIntent],
        expectation: RecoveryExpectation
    ) throws -> [DistributionLinkOwnership] {
        let runtime = try decodeRuntime(operation)
        if expectation == .old {
            let expectedScopes = Set(bindings.map(\.scope.targetScopeKey))
            let actualScopes = Set(runtime.oldOwnership.map(\.targetScopeKey))
            let wire = try DistributionOperationPayloadCodec.decode(
                DistributionPlanWire.self,
                from: operation.planPayload
            )
            let selected = Set(wire.repairScopeKeys ?? [])
            let complete = if wire.repairIntent == nil {
                actualScopes == expectedScopes
            } else {
                actualScopes.isSubset(of: expectedScopes)
                    && expectedScopes.subtracting(selected).isSubset(of: actualScopes)
            }
            guard complete else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "journal has no complete old ownership snapshot"
                )
            }
            return try runtime.oldOwnership.map {
                try DistributionLinkOwnership(
                    skillID: operation.skillID,
                    targetScopeKey: $0.targetScopeKey,
                    appliedOperationID: try SSOTOperationID(bytes: $0.appliedOperationID),
                    rootIdentity: try ManagedItemIdentityCodec.decode($0.rootIdentity),
                    entryIdentity: try ManagedItemIdentityCodec.decode($0.entryIdentity),
                    absoluteLinkTarget: $0.absoluteLinkTarget,
                    verifiedAtMilliseconds: $0.verifiedAtMilliseconds
                )
            }
        }

        let preflight = try decodePreflight(operation).actions
        let oldOwnership = try expectedOwnership(
            operation: operation,
            bindings: try decodeBindingIntents(operation.oldBindings, skillID: operation.skillID),
            expectation: .old
        )
        let wire = try DistributionOperationPayloadCodec.decode(
            DistributionPlanWire.self,
            from: operation.planPayload
        )
        let repairIntent = wire.repairIntent.flatMap(DistributionRepairIntent.init)
        let selectedRepairScopes = Set(wire.repairScopeKeys ?? [])
        return try bindings.map { binding in
            if repairIntent != nil,
               !selectedRepairScopes.contains(binding.scope.targetScopeKey),
               let old = oldOwnership.first(where: {
                   $0.targetScopeKey == binding.scope.targetScopeKey
               }) {
                return old
            }
            if let actionIndex = preflight.firstIndex(where: {
                $0.kind == DistributionFilesystemActionKind.createSymlink.rawValue
                    && $0.targetScopeKey == binding.scope.targetScopeKey
            }), let created = runtime.created.first(where: {
                $0.actionIndex == actionIndex
            }) {
                return try DistributionLinkOwnership(
                    skillID: operation.skillID,
                    targetScopeKey: binding.scope.targetScopeKey,
                    appliedOperationID: operation.operationID,
                    rootIdentity: try ManagedItemIdentityCodec.decode(created.rootIdentity),
                    entryIdentity: try ManagedItemIdentityCodec.decode(created.entryIdentity),
                    absoluteLinkTarget: created.absoluteLinkTarget,
                    verifiedAtMilliseconds: operation.createdAtMilliseconds
                )
            }
            guard let old = oldOwnership.first(where: {
                $0.targetScopeKey == binding.scope.targetScopeKey
            }) else {
                throw DistributionSymlinkExecutorError.needsRepair(
                    "journal is missing retained ownership evidence"
                )
            }
            return try DistributionLinkOwnership(
                skillID: operation.skillID,
                targetScopeKey: binding.scope.targetScopeKey,
                appliedOperationID: operation.operationID,
                rootIdentity: old.rootIdentity,
                entryIdentity: old.entryIdentity,
                absoluteLinkTarget: old.absoluteLinkTarget,
                verifiedAtMilliseconds: operation.createdAtMilliseconds
            )
        }
    }

    private func diskMatches(
        operation: DistributionOperationRecord,
        expected: RecoveryExpectation
    ) throws -> Bool {
        let preflight = try decodePreflight(operation)
        guard !preflight.ssotIdentity.isEmpty else { return false }
        var bindings = try decodeBindingIntents(
            expected == .old ? operation.oldBindings : operation.newBindings,
            skillID: operation.skillID
        )
        let wire = try DistributionOperationPayloadCodec.decode(
            DistributionPlanWire.self,
            from: operation.planPayload
        )
        let repairIntent = wire.repairIntent.flatMap(DistributionRepairIntent.init)
        if repairIntent != nil,
           !(repairIntent == .rebuildMissingSymlink && expected == .new) {
            let selected = Set(wire.repairScopeKeys ?? [])
            bindings.removeAll { selected.contains($0.scope.targetScopeKey) }
            guard try repairTargetsRemainMissing(preflight) else { return false }
        }
        let ownership = try ownershipStore.load(skillID: operation.skillID)
        return try finalReadback(
            skillID: operation.skillID,
            bindings: bindings,
            ownership: ownership,
            expectedSSOTIdentity: try expectedSSOTIdentity(from: preflight),
            allowedMissingScopeKeys: repairRemainingMissingScopeKeys(
                intent: repairIntent,
                selectedScopeKeys: wire.repairScopeKeys ?? [],
                preflight: preflight
            )
        )
    }

    private func repairTargetsMatchAppliedState(
        plan: DistributionPlan,
        preflight: DistributionPreflightPayload
    ) throws -> Bool {
        guard plan.repairIntent == .disableMissingBinding else { return true }
        return try repairTargetsRemainMissing(preflight)
    }

    private func repairTargetsRemainMissing(
        _ preflight: DistributionPreflightPayload
    ) throws -> Bool {
        for target in preflight.repairTargets {
            guard let bindingScope = distributionRepairScope(for: target.targetScopeKey),
                  let slug = try? DefaultDistributionSlug(validating: target.slug),
                  let entry = DistributionTargetCatalog.current.entry(
                      for: bindingScope,
                      slug: slug
                  ) else {
                return false
            }
            guard case .missing = try fileSystem.observe(entry) else { return false }
            let root = try fileSystem.existingRoot(for: bindingScope)
            if !target.rootIdentity.isEmpty {
                guard let root,
                      root == (try ManagedItemIdentityCodec.decode(target.rootIdentity)) else {
                    return false
                }
            }
        }
        return true
    }

    private func repairRemainingMissingScopeKeys(
        intent: DistributionRepairIntent?,
        selectedScopeKeys: [String],
        preflight: DistributionPreflightPayload
    ) -> Set<String> {
        guard intent == .disableMissingBinding else { return [] }
        return Set(preflight.repairTargets.map(\.targetScopeKey))
            .subtracting(selectedScopeKeys)
    }

    private func expectedSSOTIdentity(
        from preflight: DistributionPreflightPayload
    ) throws -> ManagedItemIdentity {
        try ManagedItemIdentityCodec.decode(preflight.ssotIdentity)
    }

    private func currentSSOTMatches(
        _ operation: DistributionOperationRecord
    ) throws -> Bool {
        let preflight = try decodePreflight(operation)
        guard !preflight.ssotIdentity.isEmpty else { return false }
        let evidence = try fileSystem.ssotEvidence(for: operation.skillID)
        return evidence.identity == (try expectedSSOTIdentity(from: preflight))
            && preflight.absoluteLinkTarget == evidence.absoluteTarget
    }

    private func preflightEntry(
        _ action: DistributionPreflightAction
    ) -> DistributionTargetEntry? {
        let scope: DistributionBindingScope
        if action.targetScopeKey == "global" {
            scope = .global
        } else if let key = action.targetScopeKey.split(separator: ":", maxSplits: 1).last,
                  let adapter = SkillPlatform.allCases.first(where: { $0.storageKey == key }) {
            scope = .agent(adapter)
        } else {
            return nil
        }
        guard let slug = try? DefaultDistributionSlug(validating: action.slug) else {
            return nil
        }
        return DistributionTargetCatalog.current.entry(for: scope, slug: slug)
    }

    private func makePreflight(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        expectedOldOwnership: [DistributionLinkOwnership],
        operationID: SSOTOperationID
    ) throws -> DistributionPreflightPayload {
        guard try configurationStore.load(skillID: skillID)
                == plan.expectedOldConfigured else {
            throw DistributionSymlinkExecutorError.conflict
        }
        let ssotEvidence = try fileSystem.ssotEvidence(for: skillID)
        let target = ssotEvidence.absoluteTarget
        let ssotIdentity = try ManagedItemIdentityCodec.encode(ssotEvidence.identity)
        let actions = try plan.filesystemActions.enumerated().map { index, action in
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
                    ssotIdentity: ssotIdentity,
                    rootIdentity: try root.map(ManagedItemIdentityCodec.encode) ?? Data(),
                    entryIdentity: nil,
                    temporaryName: distributionTemporaryName(operationID, actionIndex: index)
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
                    ssotIdentity: ssotIdentity,
                    rootIdentity: try ManagedItemIdentityCodec.encode(ownership.rootIdentity),
                    entryIdentity: try ManagedItemIdentityCodec.encode(ownership.entryIdentity),
                    temporaryName: distributionTemporaryName(operationID, actionIndex: index)
                )
            case .createCopy, .refreshCopy, .discardCopyDrift, .removeCopy,
                 .replaceSymlinkWithCopy, .replaceCopyWithSymlink:
                throw DistributionSymlinkExecutorError.conflict
            }
        }
        let repairTargets = try makeRepairPreflightTargets(
            skillID: skillID,
            plan: plan,
            expectedOldBindings: expectedOldBindings,
            expectedOldOwnership: expectedOldOwnership,
            absoluteLinkTarget: target
        )
        return DistributionPreflightPayload(
            actions: actions,
            ssotIdentity: ssotIdentity,
            absoluteLinkTarget: target,
            expectedOldConfigured: plan.expectedOldConfigured,
            desiredConfigured: plan.desiredConfigured,
            repairTargets: repairTargets
        )
    }

    private func makeRepairPreflightTargets(
        skillID: SkillID,
        plan: DistributionPlan,
        expectedOldBindings: [DistributionBinding],
        expectedOldOwnership: [DistributionLinkOwnership],
        absoluteLinkTarget: String
    ) throws -> [DistributionRepairPreflightTarget] {
        guard plan.repairIntent != nil else { return [] }
        let bindings = Dictionary(uniqueKeysWithValues: expectedOldBindings.map {
            ($0.scope.targetScopeKey, $0)
        })
        let scopeKeys: [String]
        switch plan.repairIntent {
        case .disableMissingBinding:
            scopeKeys = try expectedOldBindings.compactMap { binding in
                guard let entry = DistributionTargetCatalog.current.entry(
                    for: binding.scope,
                    slug: binding.distributionSlug
                ) else {
                    throw DistributionSymlinkExecutorError.conflict
                }
                switch try observe(
                    entry: entry,
                    skillID: skillID,
                    ownership: expectedOldOwnership
                ) {
                case .missing:
                    return binding.scope.targetScopeKey
                case .managed:
                    return nil
                default:
                    throw DistributionSymlinkExecutorError.conflict
                }
            }
            guard Set(plan.repairScopeKeys).isSubset(of: Set(scopeKeys)) else {
                throw DistributionSymlinkExecutorError.conflict
            }
        case .rebuildMissingSymlink:
            scopeKeys = plan.repairScopeKeys
        case nil:
            return []
        }
        return try scopeKeys.map { scopeKey in
            guard let binding = bindings[scopeKey],
                  let entry = DistributionTargetCatalog.current.entry(
                      for: binding.scope,
                      slug: binding.distributionSlug
                  ),
                  try observe(
                      entry: entry,
                      skillID: skillID,
                      ownership: expectedOldOwnership
                  ) == .missing else {
                throw DistributionSymlinkExecutorError.conflict
            }
            let root = try fileSystem.existingRoot(for: binding.scope)
            if let old = expectedOldOwnership.first(where: {
                $0.targetScopeKey == scopeKey
            }) {
                guard let root,
                      old.rootIdentity == root,
                      old.absoluteLinkTarget == absoluteLinkTarget else {
                    throw DistributionSymlinkExecutorError.conflict
                }
            }
            return DistributionRepairPreflightTarget(
                targetScopeKey: scopeKey,
                slug: binding.distributionSlug.value,
                rootIdentity: try root.map(ManagedItemIdentityCodec.encode) ?? Data()
            )
        }.sorted { utf8Precedes($0.targetScopeKey, $1.targetScopeKey) }
    }

    private func observe(
        entry: DistributionTargetEntry,
        skillID: SkillID,
        ownership: [DistributionLinkOwnership]
    ) throws -> DistributionTargetObservation {
        switch try fileSystem.observe(entry) {
        case .missing:
            return DistributionTargetObservation.missing
        case .unavailable:
            return DistributionTargetObservation.unavailable
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
        quarantined: [Int: DistributionQuarantinedSymlink],
        pending: [Int: DistributionRuntimeEvidence.Pending] = [:],
        oldOwnership: [DistributionLinkOwnership] = []
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
        let oldOwnershipEvidence = try oldOwnership.map {
            DistributionRuntimeEvidence.OldOwnership(
                targetScopeKey: $0.targetScopeKey,
                appliedOperationID: $0.appliedOperationID.bytes,
                rootIdentity: try ManagedItemIdentityCodec.encode($0.rootIdentity),
                entryIdentity: try ManagedItemIdentityCodec.encode($0.entryIdentity),
                absoluteLinkTarget: $0.absoluteLinkTarget,
                verifiedAtMilliseconds: $0.verifiedAtMilliseconds
            )
        }.sorted { $0.targetScopeKey < $1.targetScopeKey }
        let pendingEvidence = pending.values.sorted { $0.actionIndex < $1.actionIndex }
        return try DistributionOperationPayloadCodec.encode(
            DistributionRuntimeEvidence(
                created: createdEvidence,
                removed: removedEvidence,
                oldOwnership: oldOwnershipEvidence,
                pending: pendingEvidence
            )
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
            if plan.repairIntent != nil,
               !plan.repairScopeKeys.contains(binding.scope.targetScopeKey),
               let old = oldOwnership.first(where: {
                   $0.targetScopeKey == binding.scope.targetScopeKey
               }) {
                return old
            }
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

    private func finalReadback(
        skillID: SkillID,
        bindings: [DistributionBindingIntent],
        ownership: [DistributionLinkOwnership],
        expectedSSOTIdentity: ManagedItemIdentity,
        allowedMissingScopeKeys: Set<String> = []
    ) throws -> Bool {
        let target = try fileSystem.ssotEvidence(for: skillID)
        guard target.identity == expectedSSOTIdentity else { return false }
        for binding in bindings {
            guard let entry = DistributionTargetCatalog.current.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ), let row = ownership.first(where: {
                $0.targetScopeKey == binding.scope.targetScopeKey
            }), row.absoluteLinkTarget == target.absoluteTarget else {
                return false
            }
            if allowedMissingScopeKeys.contains(binding.scope.targetScopeKey) {
                guard case .missing = try fileSystem.observe(entry) else {
                    return false
                }
                continue
            }
            guard case .symlink(
                let root,
                let entryIdentity,
                let absoluteTarget
            ) = try fileSystem.observe(entry),
            root == row.rootIdentity, entryIdentity == row.entryIdentity,
            absoluteTarget == row.absoluteLinkTarget else {
                return false
            }
        }
        return true
    }
}

private nonisolated func distributionTemporaryName(
    _ operationID: SSOTOperationID,
    actionIndex: Int
) -> String {
    ".skillsmanager-distribution-\(operationID.uuid.uuidString.lowercased())-\(actionIndex)"
}

private extension Array {
    nonisolated subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
