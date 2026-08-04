import Foundation

nonisolated struct SkillDiscoveryBatchCandidateID: Hashable, Sendable {
    let candidateIdentity: ManagedItemIdentity?
    let fallback: SkillDiscoveryItemID?
}

nonisolated struct SkillDiscoveryBatchAlias: Hashable, Sendable, Identifiable {
    let scope: SkillDiscoveryScope
    let url: URL
    let isDirect: Bool

    var id: String {
        "\(scope.sortKey)\0\(url.path)"
    }
}

nonisolated struct SkillDiscoveryBatchCandidate: Hashable, Sendable, Identifiable {
    let id: SkillDiscoveryBatchCandidateID
    let observation: SkillDiscoveryObservation
    let aliases: [SkillDiscoveryBatchAlias]
    let sourceEvidence: Set<ProviderAliasIdentity>
    let hasConflictingManagementEvidence: Bool

    var allowedActions: Set<ManagedSkillImportAction> {
        guard !hasConflictingManagementEvidence else { return [] }
        return ManagedSkillImportService.allowedActions(for: observation)
    }

    var selectionBlockReason: String? {
        hasConflictingManagementEvidence
            ? "Verified locations disagree about the managed Skill identity."
            : nil
    }

    var defaultAction: ManagedSkillImportAction? {
        guard observation.status == .unmanaged || observation.status == .claimable,
              allowedActions.count == 1 else { return nil }
        return allowedActions.first
    }

    var isSelectable: Bool {
        !allowedActions.isEmpty
    }

    static func canonicalCandidates(
        from items: [SkillDiscoveryViewModel.Item]
    ) -> [Self] {
        var groups: [SkillDiscoveryBatchCandidateID: [SkillDiscoveryObservation]] = [:]
        for item in items {
            let observation = item.observation
            let hasUsableCandidateIdentity = observation.candidateIdentity.map {
                $0.persistedComponents.inode != 0 || $0.persistedComponents.device != 0
            } ?? false
            let key = SkillDiscoveryBatchCandidateID(
                candidateIdentity: hasUsableCandidateIdentity
                    ? observation.candidateIdentity : nil,
                fallback: hasUsableCandidateIdentity ? nil : item.id
            )
            groups[key, default: []].append(observation)
        }

        return groups.map { key, observations in
            let sorted = observations.sorted(by: canonicalObservationPrecedes)
            let managedEvidence = sorted.filter {
                $0.status == .managed || $0.status == .claimable
            }
            let matchedSkillIDs = Set(managedEvidence.compactMap(\.matchedSkillID))
            let hasConflictingManagementEvidence = matchedSkillIDs.count > 1
                || managedEvidence.contains { $0.matchedSkillID == nil }
            let canonical = managedEvidence.first { $0.status == .managed }
                ?? managedEvidence.first { $0.status == .claimable }
                ?? sorted.first!
            let merged = SkillDiscoveryObservation(
                roots: canonical.roots,
                rootIdentity: canonical.rootIdentity,
                rawRelativeLocator: canonical.rawRelativeLocator,
                relativeLocator: canonical.relativeLocator,
                relativeLocatorKey: canonical.relativeLocatorKey,
                candidateIdentity: canonical.candidateIdentity,
                symbolicLinkIdentity: canonical.symbolicLinkIdentity,
                locationRevision: canonical.locationRevision,
                fingerprint: canonical.fingerprint,
                providerAliases: observations.reduce(into: Set<ProviderAliasIdentity>()) {
                    $0.formUnion($1.providerAliases)
                },
                status: hasConflictingManagementEvidence ? .conflict : canonical.status,
                reason: hasConflictingManagementEvidence ? .evidenceConflict : canonical.reason,
                matchedSkillID: hasConflictingManagementEvidence ? nil : canonical.matchedSkillID,
                matchedSourceKey: hasConflictingManagementEvidence
                    ? nil : canonical.matchedSourceKey
            )
            let aliases = observations
                .flatMap { observation in
                    observation.roots.map { root in
                        SkillDiscoveryBatchAlias(
                            scope: root.scope,
                            url: root.url.appendingPathComponent(
                                observation.rawRelativeLocator,
                                isDirectory: true
                            ),
                            isDirect: observation.symbolicLinkIdentity == nil
                        )
                    }
                }
                .reduce(into: [SkillDiscoveryBatchAlias]()) { result, alias in
                    if !result.contains(alias) { result.append(alias) }
                }
                .sorted {
                    if $0.isDirect != $1.isDirect { return $0.isDirect }
                    return ($0.scope.sortKey, $0.url.path) < ($1.scope.sortKey, $1.url.path)
                }
            return Self(
                id: key,
                observation: merged,
                aliases: aliases,
                sourceEvidence: merged.providerAliases,
                hasConflictingManagementEvidence: hasConflictingManagementEvidence
            )
        }
        .sorted { skillDiscoveryObservationPrecedes($0.observation, $1.observation) }
    }
}

private nonisolated func canonicalObservationPrecedes(
    _ lhs: SkillDiscoveryObservation,
    _ rhs: SkillDiscoveryObservation
) -> Bool {
    if (lhs.symbolicLinkIdentity == nil) != (rhs.symbolicLinkIdentity == nil) {
        return lhs.symbolicLinkIdentity == nil
    }
    return skillDiscoveryObservationPrecedes(lhs, rhs)
}

nonisolated enum SkillDiscoveryBatchState: Equatable, Sendable {
    case idle
    case selecting
    case preparing
    case ready
    case executing
    case completed
}

nonisolated enum SkillDiscoveryBatchManagementResult: Hashable, Sendable {
    case created
    case claimed
    case alreadyManaged
    case failed(String)
    case skipped(String)
}

nonisolated enum SkillDiscoveryBatchDistributionResult: Hashable, Sendable {
    case distributed
    case noChanges
    case managedUndistributed
    case indeterminate(String)
    case notApplicable(String)
}

nonisolated struct SkillDiscoveryBatchPreviewItem: Sendable, Identifiable {
    let id: SkillDiscoveryBatchCandidateID
    let action: ManagedSkillImportAction
    let token: ManagedSkillImportToken?
    let displayName: String
    let skillID: SkillID?
    let distributionSlug: DefaultDistributionSlug?
    let sourceURLs: [URL]
    let reason: String?
    let plan: DistributionPlan?
    let canonicalPlan: Data?
}

nonisolated struct SkillDiscoveryBatchPreview: Sendable {
    let generation: UInt64
    let scope: ManagedLocalImportScope
    let items: [SkillDiscoveryBatchPreviewItem]

    var executableItems: [SkillDiscoveryBatchPreviewItem] {
        items.filter { $0.token != nil }
    }
}

nonisolated struct SkillDiscoveryBatchResultItem: Hashable, Sendable, Identifiable {
    let id: SkillDiscoveryBatchCandidateID
    let action: ManagedSkillImportAction
    let displayName: String
    let sourceURLs: [URL]
    let management: SkillDiscoveryBatchManagementResult
    let distribution: SkillDiscoveryBatchDistributionResult
}

nonisolated struct SkillDiscoveryBatchSummary: Equatable, Sendable {
    let total: Int
    let completed: Int
    let created: Int
    let claimed: Int
    let alreadyManaged: Int
    let skipped: Int
    let failed: Int
    let distributed: Int
    let needsAttention: Int

    static let empty = Self(
        items: []
    )

    init(items: [SkillDiscoveryBatchResultItem]) {
        total = items.count
        completed = items.count { item in
            switch item.management {
            case .created, .claimed, .alreadyManaged: true
            case .failed, .skipped: false
            }
        }
        created = items.count { if case .created = $0.management { true } else { false } }
        claimed = items.count { if case .claimed = $0.management { true } else { false } }
        alreadyManaged = items.count {
            if case .alreadyManaged = $0.management { true } else { false }
        }
        skipped = items.count { if case .skipped = $0.management { true } else { false } }
        failed = items.count { if case .failed = $0.management { true } else { false } }
        distributed = items.count { if case .distributed = $0.distribution { true } else { false } }
        needsAttention = items.count {
            switch $0.distribution {
            case .managedUndistributed, .indeterminate: true
            case .distributed, .noChanges, .notApplicable: false
            }
        }
    }
}
