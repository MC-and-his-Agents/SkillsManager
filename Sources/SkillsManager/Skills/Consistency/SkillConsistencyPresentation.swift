import Foundation

nonisolated enum SkillConsistencyPresentation {
    enum Status: Sendable, Equatable {
        case healthy
        case findings
        case incomplete
        case blocked
        case operationInProgress
        case needsRepair

        var title: String {
            switch self {
            case .healthy: "Healthy"
            case .findings: "Review needed"
            case .incomplete: "Audit incomplete"
            case .blocked: "Library unavailable"
            case .operationInProgress: "Operation in progress"
            case .needsRepair: "Repair required"
            }
        }

        var systemImage: String {
            switch self {
            case .healthy: "checkmark.shield"
            case .findings: "exclamationmark.triangle"
            case .incomplete: "questionmark.folder"
            case .blocked: "lock.trianglebadge.exclamationmark"
            case .operationInProgress: "clock.arrow.circlepath"
            case .needsRepair: "wrench.and.screwdriver"
            }
        }

        var allowsWrites: Bool { self == .findings }
    }

    enum Severity: Int, Sendable, Comparable {
        case information
        case warning
        case blocking

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Action: Hashable, Sendable {
        case rebuildMissingSymlinks(scopeKeys: Set<String>)
        case disableMissingBinding(scopeKeys: Set<String>)
        case migrate(importAction: ManagedSkillImportAction?, independent: Bool)
        case keepForNow

        var title: String {
            switch self {
            case .rebuildMissingSymlinks: "Rebuild missing links"
            case .disableMissingBinding: "Disable missing target"
            case .migrate(.importNew, true):
                "Import as independent Skill, back up and migrate"
            case .migrate(.importNew, false): "Import, back up and migrate"
            case .migrate(.claimExisting, _): "Claim, back up and migrate"
            case .migrate(nil, _): "Back up and migrate"
            case .keepForNow: "Keep for now"
            }
        }
    }

    struct Finding: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let detail: String
        let locator: String?
        let severity: Severity
        let actions: [Action]
        let observation: SkillDiscoveryObservation?
        let skillID: SkillID?
        let affectedFindingIDs: Set<String>
    }

    struct Snapshot: Sendable, Equatable {
        let status: Status
        let managedSkillCount: Int
        let observedSkillCount: Int
        let findings: [Finding]
        let canonicalBytes: Data

        var allowsWrites: Bool { status.allowsWrites }
    }

    static func filteredFindings(
        _ findings: [Finding],
        query: String
    ) -> [Finding] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return findings }
        return findings.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
                || $0.locator?.localizedCaseInsensitiveContains(query) == true
        }
    }

    static func makeSnapshot(_ prepared: SkillConsistencyAuditPrepared) throws -> Snapshot {
        guard try SkillConsistencyAuditManifestCodec.encode(prepared.manifest)
            == prepared.canonicalBytes else {
            throw SkillConsistencyAuditError.sourceChanged
        }

        let manifest = prepared.manifest
        let skillNames = try Dictionary(uniqueKeysWithValues: manifest.managedSkills.map {
            let payload = try SSOTWritePayloadCodec.decode($0.payload)
            return ($0.skillID, payload.skill.displayName.value)
        })
        let missingScopes = missingSymlinkScopes(in: manifest)
        var findings = distributionFindings(
            manifest: manifest,
            skillNames: skillNames,
            missingScopes: missingScopes
        )
        findings.append(contentsOf: try historicalFindings(prepared))
        findings.append(contentsOf: healthFindings(manifest))
        findings.sort(by: findingPrecedes)

        return Snapshot(
            status: status(manifest: manifest, findings: findings),
            managedSkillCount: manifest.managedSkills.count,
            observedSkillCount: manifest.discovery.observations.count,
            findings: findings,
            canonicalBytes: prepared.canonicalBytes
        )
    }

    private static func missingSymlinkScopes(
        in manifest: SkillConsistencyAuditManifest
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for distribution in manifest.distributions {
            guard let managed = manifest.managedSkills.first(where: {
                $0.skillID == distribution.skillID
            }) else { continue }
            for target in distribution.targets where target.observation.kind == "missing" {
                guard managed.bindings.contains(where: {
                    $0.scopeKey == target.scopeKey
                        && $0.slugKey == target.slugKey
                        && $0.syncMode == DistributionSyncMode.symlink.rawValue
                }) else { continue }
                result[distribution.skillID, default: []].insert(target.scopeKey)
            }
        }
        return result
    }

    private static func distributionFindings(
        manifest: SkillConsistencyAuditManifest,
        skillNames: [String: String],
        missingScopes: [String: Set<String>]
    ) -> [Finding] {
        var findings: [Finding] = []
        for distribution in manifest.distributions {
            let name = skillNames[distribution.skillID] ?? distribution.skillID
            guard let managed = manifest.managedSkills.first(where: {
                $0.skillID == distribution.skillID
            }) else { continue }
            for target in distribution.targets {
                let binding = managed.bindings.first {
                    $0.scopeKey == target.scopeKey && $0.slugKey == target.slugKey
                }
                guard let detail = distributionDetail(
                    target,
                    binding: binding,
                    expectedSkillID: distribution.skillID
                ) else {
                    continue
                }
                let id = distributionFindingID(
                    skillID: distribution.skillID,
                    target: target
                )
                var actions: [Action] = [.keepForNow]
                var affectedIDs: Set<String> = [id]
                if target.observation.kind == "missing",
                   binding?.syncMode == DistributionSyncMode.symlink.rawValue,
                   let scopes = missingScopes[distribution.skillID],
                   !scopes.isEmpty {
                    actions.insert(
                        .rebuildMissingSymlinks(scopeKeys: scopes),
                        at: 0
                    )
                    actions.insert(
                        .disableMissingBinding(scopeKeys: [target.scopeKey]),
                        at: 1
                    )
                    affectedIDs = Set(distribution.targets.compactMap {
                        guard scopes.contains($0.scopeKey),
                              $0.observation.kind == "missing" else { return nil }
                        return distributionFindingID(
                            skillID: distribution.skillID,
                            target: $0
                        )
                    })
                }
                findings.append(Finding(
                    id: id,
                    title: "\(name) · \(scopeTitle(target.scopeKey))",
                    detail: detail,
                    locator: target.canonicalLocator,
                    severity: actions.count > 1 ? .warning : .blocking,
                    actions: actions,
                    observation: nil,
                    skillID: UUID(uuidString: distribution.skillID).map(SkillID.init),
                    affectedFindingIDs: affectedIDs
                ))
            }
        }
        return findings
    }

    private static func distributionDetail(
        _ target: SkillConsistencyAuditDistributionTarget,
        binding: SkillConsistencyAuditBinding?,
        expectedSkillID: String
    ) -> String? {
        switch target.observation.kind {
        case "managed"
            where target.observation.skillID == expectedSkillID
                && target.observation.ssotDirectoryName == expectedSkillID:
            return nil
        case "managed":
            return "The managed link points to a different Skill."
        case "copy"
            where target.observation.copyState
                == DistributionCopyObservationState.inSync.rawValue:
            return nil
        case "missing" where binding?.syncMode == DistributionSyncMode.symlink.rawValue:
            return "The managed Symlink is missing."
        case "missing":
            return "The managed target is missing and requires a Copy/Fork decision."
        case "copy":
            return "The managed Copy has changed and requires an explicit Fork decision."
        case "unknown_object":
            return "Another file or directory occupies this managed target."
        case "unavailable":
            return "This target could not be inspected."
        default:
            return "The target state is not supported by this repair assistant."
        }
    }

    private static func distributionFindingID(
        skillID: String,
        target: SkillConsistencyAuditDistributionTarget
    ) -> String {
        "distribution|\(skillID)|\(target.scopeKey)|\(target.slugKey)"
    }

    private static func historicalFindings(
        _ prepared: SkillConsistencyAuditPrepared
    ) throws -> [Finding] {
        let manifestCandidates = prepared.manifest.discovery.observations.filter {
            $0.managedDistributionTarget == nil
        }
        let candidates = try prepared.discoveryObservations.compactMap { observation
            -> (Data, SkillDiscoveryObservation, ManagedSkillImportAction?, Bool)? in
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
            let structurallySupported = historicalCandidateIsSupported(candidate.1)
            let executable = candidate.3
                && matches.count == 1
                && rawCounts[candidate.0] == 1
                && structurallySupported
            let stableID = "historical|\(candidate.0.base64EncodedString())"
            let id = executable ? stableID : "\(stableID)|\(index)"
            let detail: String
            if matches.count != 1 {
                detail = "The audit could not bind this directory to one stable observation."
            } else if !structurallySupported {
                detail = "This directory is outside the supported managed distribution roots."
            } else if !candidate.3 {
                detail = "This directory cannot be safely imported: "
                    + "\(candidate.1.reason?.rawValue ?? candidate.1.status.rawValue)."
            } else if candidate.1.status == .conflict {
                detail = "Conflicting identity evidence requires import as an independent Skill."
            } else {
                detail = "This directory is not yet distributed through the managed library."
            }
            return Finding(
                id: id,
                title: candidate.1.relativeLocator,
                detail: detail,
                locator: candidate.1.displayURLs.first?.standardizedFileURL.path,
                severity: executable ? .warning : .blocking,
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

    private static func historicalCandidateIsSupported(
        _ observation: SkillDiscoveryObservation
    ) -> Bool {
        guard observation.roots.count == 1,
              let root = observation.roots.first,
              root.scope.kind != .custom,
              observation.candidateIdentity != nil,
              observation.fingerprint != nil,
              observation.rawRelativeLocator == observation.relativeLocator else {
            return false
        }
        if root.scope.kind == .agent {
            return root.scope.adapterCode != nil && root.scope.customPathID == nil
        }
        return root.scope == .global
    }

    private static func isManagedDistributionObservation(
        _ observation: SkillConsistencyAuditDiscoveryObservation,
        manifest: SkillConsistencyAuditManifest
    ) -> Bool {
        manifest.managedSkills.lazy.flatMap(\.bindings).contains { binding in
            observation.relativeLocatorKey == binding.slugKey
                && observation.roots.contains {
                    $0.kind == binding.scopeKind
                        && $0.adapterCode == binding.adapterCode
                        && $0.customPathID == nil
                }
        }
    }

    private static func healthFindings(
        _ manifest: SkillConsistencyAuditManifest
    ) -> [Finding] {
        var findings = manifest.health.map {
            Finding(
                id: "health|\($0.code)|\($0.subjectKind)|\($0.subjectID)",
                title: $0.code,
                detail: "Recommended action: \($0.recommendedActionCode)",
                locator: nil,
                severity: $0.blocking ? .blocking : .warning,
                actions: [.keepForNow],
                observation: nil,
                skillID: nil,
                affectedFindingIDs: []
            )
        }
        findings.append(contentsOf: manifest.discovery.rootDiagnostics.map {
            Finding(
                id: "root|\($0.root.scopeKey)|\($0.root.locator)|\($0.reason)",
                title: scopeTitle($0.root.scopeKey),
                detail: "The root could not be fully audited: \($0.reason).",
                locator: $0.root.locator,
                severity: .blocking,
                actions: [.keepForNow],
                observation: nil,
                skillID: nil,
                affectedFindingIDs: []
            )
        })
        return findings
    }

    private static func status(
        manifest: SkillConsistencyAuditManifest,
        findings: [Finding]
    ) -> Status {
        if manifest.coverage == .incomplete { return .incomplete }
        if manifest.health.contains(where: \.blocking) { return .blocked }
        if manifest.distributions.contains(where: {
            $0.status == DistributionReconcileStatus.operationInProgress.rawValue
        }) {
            return .operationInProgress
        }
        if manifest.distributions.contains(where: {
            $0.status == DistributionReconcileStatus.needsRepair.rawValue
        }) {
            return .needsRepair
        }
        return findings.isEmpty ? .healthy : .findings
    }

    private static func findingPrecedes(_ lhs: Finding, _ rhs: Finding) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        return (lhs.title, lhs.id) < (rhs.title, rhs.id)
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

    private static func scopeTitle(_ scopeKey: String) -> String {
        if scopeKey == "global" { return "All compatible Agents" }
        guard scopeKey.hasPrefix("agent:") else { return scopeKey }
        let code = String(scopeKey.dropFirst("agent:".count))
        return SkillPlatform.allCases.first { $0.storageKey == code }?.rawValue ?? code
    }
}
