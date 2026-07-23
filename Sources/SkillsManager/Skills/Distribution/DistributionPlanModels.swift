import Foundation

nonisolated enum DistributionDesiredScope: Sendable {
    case disabled
    case global(DefaultDistributionSlug)
    case agents(Set<SkillPlatform>, DefaultDistributionSlug)

    var distributionSlug: DefaultDistributionSlug? {
        switch self {
        case .disabled: nil
        case .global(let slug), .agents(_, let slug): slug
        }
    }
}
nonisolated enum DistributionTargetObservation: Hashable, Sendable {
    case missing
    case managed(skillID: SkillID, ssotDirectoryName: String)
    case unknownObject
    case unavailable
}

nonisolated enum DistributionConflictReason: String, CaseIterable, Sendable {
    case invalidDesiredScope = "invalid_desired_scope"
    case unsupportedAdapter = "unsupported_adapter"
    case globalCoverageMismatch = "global_coverage_mismatch"
    case dedicatedTargetUnavailable = "dedicated_target_unavailable"
    case targetUnavailable = "target_unavailable"
    case currentBindingMissing = "current_binding_missing"
    case managedTargetMismatch = "managed_target_mismatch"
    case unknownObject = "unknown_object"
    case slugOccupied = "slug_occupied"

    var canonicalRank: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

nonisolated enum DistributionFilesystemActionKind: String, Sendable {
    case removeSymlink = "remove_symlink"
    case createSymlink = "create_symlink"

    var canonicalRank: Int {
        switch self {
        case .removeSymlink: 0
        case .createSymlink: 1
        }
    }
}

nonisolated struct DistributionFilesystemAction: Hashable, Sendable {
    let kind: DistributionFilesystemActionKind
    let entry: DistributionTargetEntry
    let ssotLocator: String
}

nonisolated struct DistributionPlanConflict: Hashable, Sendable {
    let reason: DistributionConflictReason
    let targetScopeKey: String
    let targetRank: Int
    let slugKey: String
    let canonicalLocator: String
}

nonisolated enum DistributionPlanStatus: String, Sendable {
    case executable
    case noOp = "no_op"
    case blocked
}

nonisolated struct DistributionPlan: Sendable {
    let status: DistributionPlanStatus
    let filesystemActions: [DistributionFilesystemAction]
    let bindingsChanged: Bool
    let bindingReplacement: [DistributionBindingIntent]
    let conflicts: [DistributionPlanConflict]

    func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CanonicalDistributionPlan(self))
    }

    func canonicalJSONString() throws -> String {
        String(decoding: try canonicalJSONData(), as: UTF8.self)
    }
}

nonisolated func distributionActionPrecedes(
    _ lhs: DistributionFilesystemAction,
    _ rhs: DistributionFilesystemAction
) -> Bool {
    if lhs.kind.canonicalRank != rhs.kind.canonicalRank {
        return lhs.kind.canonicalRank < rhs.kind.canonicalRank
    }
    if lhs.entry.target.rank != rhs.entry.target.rank {
        return lhs.entry.target.rank < rhs.entry.target.rank
    }
    if lhs.entry.slugKey != rhs.entry.slugKey {
        return utf8Precedes(lhs.entry.slugKey, rhs.entry.slugKey)
    }
    return utf8Precedes(lhs.entry.canonicalLocator, rhs.entry.canonicalLocator)
}

nonisolated func distributionConflictPrecedes(
    _ lhs: DistributionPlanConflict,
    _ rhs: DistributionPlanConflict
) -> Bool {
    if lhs.reason.canonicalRank != rhs.reason.canonicalRank {
        return lhs.reason.canonicalRank < rhs.reason.canonicalRank
    }
    if lhs.targetRank != rhs.targetRank {
        return lhs.targetRank < rhs.targetRank
    }
    if lhs.slugKey != rhs.slugKey {
        return utf8Precedes(lhs.slugKey, rhs.slugKey)
    }
    if lhs.canonicalLocator != rhs.canonicalLocator {
        return utf8Precedes(lhs.canonicalLocator, rhs.canonicalLocator)
    }
    return utf8Precedes(lhs.targetScopeKey, rhs.targetScopeKey)
}

private nonisolated struct CanonicalDistributionPlan: Encodable {
    let status: String
    let filesystemActions: [CanonicalDistributionAction]
    let bindingsChanged: Bool
    let bindingReplacement: [CanonicalDistributionBinding]
    let conflicts: [CanonicalDistributionConflict]

    enum CodingKeys: String, CodingKey {
        case status
        case filesystemActions = "filesystem_actions"
        case bindingsChanged = "bindings_changed"
        case bindingReplacement = "binding_replacement"
        case conflicts
    }

    init(_ plan: DistributionPlan) {
        status = plan.status.rawValue
        filesystemActions = plan.filesystemActions
            .sorted(by: distributionActionPrecedes)
            .map(CanonicalDistributionAction.init)
        bindingsChanged = plan.bindingsChanged
        bindingReplacement = plan.bindingReplacement
            .sorted(by: distributionBindingIntentPrecedes)
            .map(CanonicalDistributionBinding.init)
        conflicts = plan.conflicts
            .sorted(by: distributionConflictPrecedes)
            .map(CanonicalDistributionConflict.init)
    }
}

private nonisolated struct CanonicalDistributionAction: Encodable {
    let action: String
    let targetScopeKey: String
    let targetLocator: String
    let ssotLocator: String

    enum CodingKeys: String, CodingKey {
        case action
        case targetScopeKey = "target_scope_key"
        case targetLocator = "target_locator"
        case ssotLocator = "ssot_locator"
    }

    init(_ action: DistributionFilesystemAction) {
        self.action = action.kind.rawValue
        targetScopeKey = action.entry.target.scope.targetScopeKey
        targetLocator = action.entry.canonicalLocator
        ssotLocator = action.ssotLocator
    }
}

private nonisolated struct CanonicalDistributionBinding: Encodable {
    let skillID: String
    let scopeKind: String
    let adapterCode: String?
    let targetScopeKey: String
    let distributionSlug: String
    let slugKey: String
    let syncMode: String

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case scopeKind = "scope_kind"
        case adapterCode = "adapter_code"
        case targetScopeKey = "target_scope_key"
        case distributionSlug = "distribution_slug"
        case slugKey = "slug_key"
        case syncMode = "sync_mode"
    }

    init(_ binding: DistributionBindingIntent) {
        skillID = binding.skillID.directoryName
        scopeKind = binding.scope.kind
        adapterCode = binding.scope.adapter?.storageKey
        targetScopeKey = binding.scope.targetScopeKey
        distributionSlug = binding.distributionSlug.value
        slugKey = binding.distributionSlug.collisionKey
        syncMode = binding.syncMode.rawValue
    }
}

private nonisolated struct CanonicalDistributionConflict: Encodable {
    let reason: String
    let targetScopeKey: String
    let slugKey: String
    let targetLocator: String

    enum CodingKeys: String, CodingKey {
        case reason
        case targetScopeKey = "target_scope_key"
        case slugKey = "slug_key"
        case targetLocator = "target_locator"
    }

    init(_ conflict: DistributionPlanConflict) {
        reason = conflict.reason.rawValue
        targetScopeKey = conflict.targetScopeKey
        slugKey = conflict.slugKey
        targetLocator = conflict.canonicalLocator
    }
}

private nonisolated func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
