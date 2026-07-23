import Foundation

nonisolated enum DistributionSyncMode: String, Hashable, Sendable {
    case symlink
}
nonisolated enum DistributionBindingScope: Hashable, Sendable {
    case global
    case agent(SkillPlatform)

    var kind: String {
        switch self {
        case .global: "global"
        case .agent: "agent"
        }
    }

    var adapter: SkillPlatform? {
        if case .agent(let adapter) = self { adapter } else { nil }
    }

    var targetScopeKey: String {
        switch self {
        case .global: "global"
        case .agent(let adapter): "agent:\(adapter.storageKey)"
        }
    }

    var canonicalRank: Int {
        switch self {
        case .global: 0
        case .agent(.codex): 1
        case .agent(.claude): 2
        case .agent(.opencode): 3
        case .agent(.copilot): 4
        }
    }
}

nonisolated enum DistributionBindingError: Error, Equatable {
    case invalidTimestampRange
}

/// Desired Binding semantics without persistence-owned timestamps.
nonisolated struct DistributionBindingIntent: Hashable, Sendable {
    let skillID: SkillID
    let scope: DistributionBindingScope
    let distributionSlug: DefaultDistributionSlug
    let syncMode: DistributionSyncMode

    init(
        skillID: SkillID,
        scope: DistributionBindingScope,
        distributionSlug: DefaultDistributionSlug,
        syncMode: DistributionSyncMode = .symlink
    ) {
        self.skillID = skillID
        self.scope = scope
        self.distributionSlug = distributionSlug
        self.syncMode = syncMode
    }
}

/// Persisted expected distribution truth. Local discovery origins remain separate.
nonisolated struct DistributionBinding: Hashable, Sendable {
    let intent: DistributionBindingIntent
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        skillID: SkillID,
        scope: DistributionBindingScope,
        distributionSlug: DefaultDistributionSlug,
        syncMode: DistributionSyncMode = .symlink,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) throws {
        guard createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds else {
            throw DistributionBindingError.invalidTimestampRange
        }
        intent = DistributionBindingIntent(
            skillID: skillID,
            scope: scope,
            distributionSlug: distributionSlug,
            syncMode: syncMode
        )
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }

    var skillID: SkillID { intent.skillID }
    var scope: DistributionBindingScope { intent.scope }
    var distributionSlug: DefaultDistributionSlug { intent.distributionSlug }
    var syncMode: DistributionSyncMode { intent.syncMode }
}

nonisolated func distributionBindingIntentPrecedes(
    _ lhs: DistributionBindingIntent,
    _ rhs: DistributionBindingIntent
) -> Bool {
    if lhs.scope.canonicalRank != rhs.scope.canonicalRank {
        return lhs.scope.canonicalRank < rhs.scope.canonicalRank
    }
    if lhs.distributionSlug.collisionKey != rhs.distributionSlug.collisionKey {
        return lhs.distributionSlug.collisionKey.utf8.lexicographicallyPrecedes(
            rhs.distributionSlug.collisionKey.utf8
        )
    }
    return lhs.distributionSlug.value.utf8.lexicographicallyPrecedes(
        rhs.distributionSlug.value.utf8
    )
}
