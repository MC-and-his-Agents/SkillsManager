import Foundation

nonisolated extension SkillConsistencyPresentation {
    static func historicalFindings(
        _ prepared: SkillConsistencyAuditPrepared
    ) throws -> [Finding] {
        let manifestCandidates = prepared.manifest.discovery.observations.filter {
            $0.managedDistributionTarget == nil
        }
        let candidates = try prepared.discoveryObservations.compactMap { observation
            -> (Data, SkillDiscoveryObservation, ManagedSkillImportAction?, Bool)? in
            guard observation.reason != .containerDirectory else { return nil }
            guard observation.symbolicLinkIdentity == nil || observation.status != .managed else {
                return nil
            }
            let allowed = ManagedSkillImportService.allowedActions(for: observation)
            let managedCandidate = observation.status == .managed
                && observation.matchedSkillID != nil
            let wire = try SkillConsistencyAuditWire.discoveryObservation(observation)
            guard !isManagedDistributionObservation(wire, manifest: prepared.manifest) else {
                return nil
            }
            let bytes = try SkillConsistencyAuditManifestCodec.encode(wire)
            let action = allowed.sorted(by: importActionPrecedes).first
            return (bytes, observation, action, managedCandidate || !allowed.isEmpty)
        }.sorted {
            if $0.0 != $1.0 { return $0.0.lexicographicallyPrecedes($1.0) }
            return $0.1.relativeLocator < $1.1.relativeLocator
        }

        let rawCounts = Dictionary(grouping: candidates, by: \.0).mapValues(\.count)
        return try candidates.enumerated().map { index, candidate in
            let wire = try SkillConsistencyAuditWire.discoveryObservation(candidate.1)
            let matches = manifestCandidates.filter { $0 == wire }
            let disposition = historicalCandidateDisposition(candidate.1)
            let executable = candidate.3
                && matches.count == 1
                && rawCounts[candidate.0] == 1
                && disposition.allowsMigration
            let stableID = "historical|\(candidate.0.base64EncodedString())"
            let id = executable ? stableID : "\(stableID)|\(index)"
            let detail: String
            let severity: Severity
            if matches.count != 1 {
                detail = "The audit could not bind this directory to one stable observation."
                severity = .blocking
            } else if rawCounts[candidate.0] != 1 {
                detail = "The audit found duplicate observations for the same directory."
                severity = .blocking
            } else if case .review(let reviewDetail, let reviewSeverity) = disposition {
                detail = reviewDetail
                severity = reviewSeverity
            } else if !candidate.3 {
                detail = "This directory cannot be safely imported: "
                    + "\(candidate.1.reason?.displayName ?? candidate.1.status.rawValue)."
                severity = .blocking
            } else if candidate.1.status == .conflict {
                detail = "Conflicting identity evidence requires import as an independent Skill."
                severity = .warning
            } else {
                detail = "This directory is not yet distributed through the managed library."
                severity = .warning
            }
            return Finding(
                id: id,
                title: candidate.1.relativeLocator,
                detail: detail,
                locator: candidate.1.displayURLs.first?.standardizedFileURL.path,
                severity: severity,
                actions: executable
                    ? [
                        .migrate(
                            importAction: candidate.2,
                            independent: candidate.1.status == .conflict
                        ),
                        .keepForNow,
                    ]
                    : [.keepForNow],
                observation: executable ? candidate.1 : nil,
                skillID: candidate.1.matchedSkillID,
                affectedFindingIDs: [id]
            )
        }
    }

    private enum HistoricalCandidateDisposition {
        case migrate
        case review(detail: String, severity: Severity)

        var allowsMigration: Bool {
            if case .migrate = self { return true }
            return false
        }
    }

    private static func historicalCandidateDisposition(
        _ observation: SkillDiscoveryObservation
    ) -> HistoricalCandidateDisposition {
        if observation.symbolicLinkIdentity != nil {
            if observation.reason == .localAssociationDrift {
                return .review(
                    detail: "This external Skill link changed after it was imported. "
                        + "Review it in Discovery; no files were changed.",
                    severity: .blocking
                )
            }
            if observation.fingerprint != nil,
               !ManagedSkillImportService.allowedActions(for: observation).isEmpty {
                return .review(
                    detail: "This external Skill link can be imported from Discovery. "
                        + "The source link and target will remain unchanged.",
                    severity: .warning
                )
            }
            return .review(
                detail: observation.reason?.displayName
                    ?? "This external Skill link cannot be read safely.",
                severity: .blocking
            )
        }
        guard observation.roots.count == 1 else {
            return .review(
                detail: "This directory is visible through multiple registered root aliases. "
                    + "Review it in Discovery; automatic migration is disabled.",
                severity: .warning
            )
        }
        guard let root = observation.roots.first else {
            return .review(
                detail: "This directory is not associated with a registered scan root.",
                severity: .blocking
            )
        }
        guard root.scope.kind != .custom else {
            return .review(
                detail: "This directory belongs to a custom scan root and cannot be migrated.",
                severity: .blocking
            )
        }
        guard observation.candidateIdentity != nil, observation.fingerprint != nil else {
            return .review(
                detail: observation.reason?.displayName
                    ?? "This directory could not produce a stable content snapshot.",
                severity: .blocking
            )
        }
        guard observation.rawRelativeLocator == observation.relativeLocator else {
            return .review(
                detail: "This directory name is not a safe canonical locator.",
                severity: .blocking
            )
        }
        if root.scope.kind == .agent {
            guard root.scope.adapterCode != nil, root.scope.customPathID == nil else {
                return .review(
                    detail: "This Agent directory is not a canonical managed distribution root.",
                    severity: .blocking
                )
            }
            return .migrate
        }
        return root.scope == .global
            ? .migrate
            : .review(
                detail: "This directory is not in a canonical managed distribution root.",
                severity: .blocking
            )
    }

    private static func isManagedDistributionObservation(
        _ observation: SkillConsistencyAuditDiscoveryObservation,
        manifest: SkillConsistencyAuditManifest
    ) -> Bool {
        manifest.managedSkills.lazy.flatMap(\.bindings).contains { binding in
            observation.relativeLocatorKey == binding.slugKey
                && observation.roots.contains {
                    isDistributionRoot($0, for: binding)
                }
        }
    }

    private static func isDistributionRoot(
        _ root: SkillConsistencyAuditDiscoveryRoot,
        for binding: SkillConsistencyAuditBinding
    ) -> Bool {
        guard root.customPathID == nil else { return false }
        if binding.scopeKind == SkillDiscoveryScopeKind.global.rawValue {
            return root.kind == SkillDiscoveryScopeKind.global.rawValue
                && root.adapterCode == nil
                && root.pathVariant == nil
        }
        guard binding.scopeKind == SkillDiscoveryScopeKind.agent.rawValue,
              root.kind == SkillDiscoveryScopeKind.agent.rawValue,
              let adapterCode = binding.adapterCode,
              root.adapterCode == adapterCode,
              let platform = SkillPlatform.allCases.first(where: {
                  $0.storageKey == adapterCode
              }) else {
            return false
        }
        return root.pathVariant == platform.dedicatedDistributionRelativePath
    }

    private static func importActionPrecedes(
        _ lhs: ManagedSkillImportAction,
        _ rhs: ManagedSkillImportAction
    ) -> Bool {
        switch (lhs, rhs) {
        case (.claimExisting, .importNew): true
        default: false
        }
    }
}
