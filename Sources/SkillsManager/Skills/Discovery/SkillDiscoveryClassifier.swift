import Foundation

nonisolated struct SkillDiscoveryCandidate: Sendable {
    let roots: [SkillDiscoveryRoot]
    let relativeLocator: String
    let relativeLocatorKey: String
    let candidateIdentity: ManagedItemIdentity?
    let fingerprint: SkillContentFingerprint?
    let providerAliases: Set<ProviderAliasIdentity>
    let terminalStatus: SkillDiscoveryStatus?
    let terminalReason: SkillDiscoveryReason?
}

nonisolated struct SkillDiscoveryClassifier {
    private struct CatalogIndex {
        let skillsByID: [SkillID: SkillDiscoveryManagedSkill]
        let skillsByFingerprint: [SkillContentFingerprint: Set<SkillID>]
        let skillsByAlias: [ProviderAliasIdentity: Set<SkillID>]
        let associations: [AssociationKey: [SkillDiscoveryLocalAssociation]]
    }

    private struct AssociationKey: Hashable {
        let scope: SkillDiscoveryScope
        let locatorKey: String
    }

    func classify(
        _ candidates: [SkillDiscoveryCandidate],
        catalog: SkillDiscoveryCatalog
    ) -> [SkillDiscoveryObservation] {
        let index = makeIndex(catalog)
        let slugConflicts = slugConflictIndices(candidates, index: index)
        return candidates.enumerated().map { candidateIndex, candidate in
            if let status = candidate.terminalStatus {
                return observation(
                    candidate,
                    status: status,
                    reason: candidate.terminalReason,
                    matchedSkillID: nil
                )
            }
            return classify(
                candidate,
                hasSlugConflict: slugConflicts.contains(candidateIndex),
                index: index
            )
        }
    }

    private func classify(
        _ candidate: SkillDiscoveryCandidate,
        hasSlugConflict: Bool,
        index: CatalogIndex
    ) -> SkillDiscoveryObservation {
        guard let fingerprint = candidate.fingerprint else {
            return observation(candidate, status: .damaged, reason: .candidateReadFailed)
        }
        let local = localEvidence(for: candidate, fingerprint: fingerprint, index: index)
        let sourceIDs = sourceSkillIDs(for: candidate, index: index)
        let fingerprintIDs = index.skillsByFingerprint[fingerprint] ?? []

        if hasSlugConflict {
            return observation(candidate, status: .conflict, reason: .scopeSlugConflict)
        }
        if let reason = local.conflict {
            return observation(candidate, status: .conflict, reason: reason)
        }
        if sourceIDs.count > 1 {
            return observation(candidate, status: .conflict, reason: .ambiguousSource)
        }
        if fingerprintIDs.count > 1 {
            return observation(candidate, status: .conflict, reason: .ambiguousFingerprint)
        }
        if evidenceConflicts(local.skillIDs, sourceIDs, fingerprintIDs) {
            return observation(candidate, status: .conflict, reason: .evidenceConflict)
        }
        if let skillID = local.skillIDs.first {
            return observation(
                candidate,
                status: .managed,
                matchedSkillID: skillID,
                sourceKey: index.skillsByID[skillID]?.sourceKey
            )
        }
        if let skillID = sourceIDs.first ?? fingerprintIDs.first {
            return observation(
                candidate,
                status: .claimable,
                matchedSkillID: skillID,
                sourceKey: index.skillsByID[skillID]?.sourceKey
            )
        }
        return observation(candidate, status: .unmanaged)
    }

    private func localEvidence(
        for candidate: SkillDiscoveryCandidate,
        fingerprint: SkillContentFingerprint,
        index: CatalogIndex
    ) -> (skillIDs: Set<SkillID>, conflict: SkillDiscoveryReason?) {
        let associations = candidate.roots.flatMap {
            index.associations[
                AssociationKey(scope: $0.scope, locatorKey: candidate.relativeLocatorKey),
                default: []
            ]
        }
        guard !associations.isEmpty else { return ([], nil) }
        let skillIDs = Set(associations.map(\.skillID))
        guard skillIDs.count == 1 else { return (skillIDs, .ambiguousLocalAssociation) }
        let drifted = associations.contains {
            $0.fingerprint != fingerprint
                || index.skillsByID[$0.skillID]?.fingerprint != fingerprint
        }
        return drifted ? (skillIDs, .localAssociationDrift) : (skillIDs, nil)
    }

    private func sourceSkillIDs(
        for candidate: SkillDiscoveryCandidate,
        index: CatalogIndex
    ) -> Set<SkillID> {
        candidate.providerAliases.reduce(into: Set<SkillID>()) { result, alias in
            result.formUnion(index.skillsByAlias[alias] ?? [])
        }
    }

    private func evidenceConflicts(_ evidence: Set<SkillID>...) -> Bool {
        let nonEmpty = evidence.filter { !$0.isEmpty }
        guard let first = nonEmpty.first else { return false }
        return nonEmpty.dropFirst().contains { $0 != first }
    }

    private func slugConflictIndices(
        _ candidates: [SkillDiscoveryCandidate],
        index: CatalogIndex
    ) -> Set<Int> {
        var groups: [String: [Int]] = [:]
        for (candidateIndex, candidate) in candidates.enumerated()
        where candidate.terminalStatus == nil {
            for root in candidate.roots {
                let key = root.scope.sortKey + "\u{0}" + candidate.relativeLocatorKey
                groups[key, default: []].append(candidateIndex)
            }
        }

        var conflicts = Set<Int>()
        for group in groups.values where group.count > 1 {
            for leftOffset in group.indices {
                for rightOffset in group.indices where rightOffset > leftOffset {
                    let leftIndex = group[leftOffset]
                    let rightIndex = group[rightOffset]
                    if candidatesConflict(candidates[leftIndex], candidates[rightIndex], index: index) {
                        conflicts.insert(leftIndex)
                        conflicts.insert(rightIndex)
                    }
                }
            }
        }
        return conflicts
    }

    private func candidatesConflict(
        _ lhs: SkillDiscoveryCandidate,
        _ rhs: SkillDiscoveryCandidate,
        index: CatalogIndex
    ) -> Bool {
        guard lhs.fingerprint == rhs.fingerprint else { return true }
        let leftSources = sourceSkillIDs(for: lhs, index: index)
        let rightSources = sourceSkillIDs(for: rhs, index: index)
        return !leftSources.isEmpty && !rightSources.isEmpty && leftSources != rightSources
    }

    private func makeIndex(_ catalog: SkillDiscoveryCatalog) -> CatalogIndex {
        let skillsByID = Dictionary(uniqueKeysWithValues: catalog.managedSkills.map {
            ($0.skillID, $0)
        })
        var skillsByFingerprint: [SkillContentFingerprint: Set<SkillID>] = [:]
        var skillsByAlias: [ProviderAliasIdentity: Set<SkillID>] = [:]
        for skill in catalog.managedSkills {
            skillsByFingerprint[skill.fingerprint, default: []].insert(skill.skillID)
            if skill.sourceKey != nil {
                for alias in skill.providerAliases {
                    skillsByAlias[alias, default: []].insert(skill.skillID)
                }
            }
        }
        let associations = Dictionary(grouping: catalog.localAssociations) {
            AssociationKey(scope: $0.scope, locatorKey: $0.relativeLocatorKey)
        }
        return CatalogIndex(
            skillsByID: skillsByID,
            skillsByFingerprint: skillsByFingerprint,
            skillsByAlias: skillsByAlias,
            associations: associations
        )
    }

    private func observation(
        _ candidate: SkillDiscoveryCandidate,
        status: SkillDiscoveryStatus,
        reason: SkillDiscoveryReason? = nil,
        matchedSkillID: SkillID? = nil,
        sourceKey: SkillDiscoverySourceKey? = nil
    ) -> SkillDiscoveryObservation {
        SkillDiscoveryObservation(
            roots: candidate.roots,
            relativeLocator: candidate.relativeLocator,
            relativeLocatorKey: candidate.relativeLocatorKey,
            candidateIdentity: candidate.candidateIdentity,
            fingerprint: candidate.fingerprint,
            providerAliases: candidate.providerAliases,
            status: status,
            reason: reason,
            matchedSkillID: matchedSkillID,
            matchedSourceKey: sourceKey
        )
    }
}
