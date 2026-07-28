import Darwin
import Foundation

nonisolated enum SkillConsistencyAuditWire {
    static func managedSkill(
        skillID: SkillID,
        domain: StoredSkillDomainSnapshot,
        bindings: [DistributionBinding]
    ) throws -> SkillConsistencyAuditManagedSkill {
        SkillConsistencyAuditManagedSkill(
            skillID: skillID.directoryName,
            revision: domain.revision,
            payload: try SSOTWritePayloadCodec.encode(domain.payload),
            bindings: try bindings.map(binding).sorted(by: bindingPrecedes)
        )
    }

    static func health(
        _ value: LibraryRuntimeDiagnostic
    ) -> SkillConsistencyAuditHealth {
        SkillConsistencyAuditHealth(
            code: value.code.rawValue,
            severity: value.severity.rawValue,
            subjectKind: value.subjectKind.rawValue,
            subjectID: value.subjectID,
            retryability: value.retryability.rawValue,
            dataPreservation: value.dataPreservation.rawValue,
            recommendedActionCode: value.recommendedActionCode,
            blocking: value.blocking
        )
    }

    static func distribution(
        skillID: SkillID,
        result: DistributionReconcileResult
    ) throws -> SkillConsistencyAuditDistribution {
        let targets = try result.observations.map {
            try distributionTarget(entry: $0.key, observation: $0.value)
        }.sorted(by: distributionTargetPrecedes)
        return SkillConsistencyAuditDistribution(
            skillID: skillID.directoryName,
            status: result.status.rawValue,
            targets: targets
        )
    }

    static func discovery(
        _ value: SkillDiscoveryResult,
        homeURL: URL,
        bindingsBySkillID: [SkillID: [DistributionBinding]],
        reconcileBySkillID: [SkillID: DistributionReconcileResult]
    ) throws -> SkillConsistencyAuditDiscovery {
        let roots = try value.observedRoots.map {
            SkillConsistencyAuditObservedRoot(
                root: discoveryRoot($0.root),
                identity: try ManagedItemIdentityCodec.encode($0.identity)
            )
        }.sorted(by: observedRootPrecedes)
        let diagnostics = value.rootDiagnostics.map {
            SkillConsistencyAuditRootDiagnostic(
                root: discoveryRoot($0.root),
                reason: $0.reason.rawValue
            )
        }.sorted(by: rootDiagnosticPrecedes)
        let observations = try value.observations.map { observation in
            try discoveryObservation(
                observation,
                attribution: attribution(
                    for: observation,
                    homeURL: homeURL,
                    bindingsBySkillID: bindingsBySkillID,
                    reconcileBySkillID: reconcileBySkillID
                )
            )
        }
        let canonicalObservations = try observations.map {
            (try SkillConsistencyAuditManifestCodec.encode($0), $0)
        }.sorted {
            $0.0.lexicographicallyPrecedes($1.0)
        }.map(\.1)
        return SkillConsistencyAuditDiscovery(
            roots: roots,
            rootDiagnostics: diagnostics,
            observations: canonicalObservations
        )
    }

    static func locator(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    static func discoveryObservation(
        _ value: SkillDiscoveryObservation
    ) throws -> SkillConsistencyAuditDiscoveryObservation {
        try discoveryObservation(value, attribution: nil)
    }

    static func skillIDPrecedes(_ lhs: SkillID, _ rhs: SkillID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    static func stableError(_ error: Error) -> SkillConsistencyAuditError {
        if let error = error as? ManagedPathError {
            switch error {
            case .rootReplaced:
                return .writerUnavailable
            case .itemChanged:
                return .sourceChanged
            case .posix(_, let code) where permissionError(code):
                return .permissionDenied
            default:
                return .rootUnavailable
            }
        }
        if let error = error as? SSOTWriterOwnershipError {
            if case .posix(_, let code) = error, permissionError(code) {
                return .permissionDenied
            }
            return .writerUnavailable
        }
        if let error = error as? DistributionSymlinkFileSystemError {
            switch error {
            case .posix(_, let code) where permissionError(code):
                return .permissionDenied
            case .entryChanged:
                return .sourceChanged
            case .unavailable:
                return .rootUnavailable
            default:
                return .inconsistentCatalog
            }
        }
        if error is ManagedRootReferenceError {
            return .writerUnavailable
        }
        if error is ManagedLocalCatalogError
            || error is SSOTJournalStoreError
            || error is DistributionBindingStoreError
            || error is ManagedItemIdentityCodecError
            || error is SSOTWritePayloadError {
            return .inconsistentCatalog
        }
        if error is SQLiteStoreError {
            return .databaseUnavailable
        }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain,
           permissionError(Int32(value.code)) {
            return .permissionDenied
        }
        return .databaseUnavailable
    }

    private static func binding(
        _ value: DistributionBinding
    ) throws -> SkillConsistencyAuditBinding {
        SkillConsistencyAuditBinding(
            skillID: value.skillID.directoryName,
            scopeKey: value.scope.targetScopeKey,
            scopeKind: value.scope.kind,
            adapterCode: value.scope.adapter?.storageKey,
            slug: value.distributionSlug.value,
            slugKey: value.distributionSlug.collisionKey,
            syncMode: value.syncMode.rawValue,
            copyBaseline: try value.copyBaseline.map(copyBaseline),
            createdAtMilliseconds: value.createdAtMilliseconds,
            updatedAtMilliseconds: value.updatedAtMilliseconds
        )
    }

    private static func copyBaseline(
        _ value: DistributionCopyBaseline
    ) throws -> SkillConsistencyAuditCopyBaseline {
        let provenance: String
        switch value.provenance {
        case .distribution:
            provenance = "distribution"
        case .copyFork:
            provenance = "copy_fork"
        }
        return SkillConsistencyAuditCopyBaseline(
            contentFingerprint: fingerprint(value.contentFingerprint),
            physicalTreeAlgorithmVersion: value.physicalTreeDigest.algorithmVersion,
            physicalTreeDigest: value.physicalTreeDigest.digest,
            rootIdentity: try ManagedItemIdentityCodec.encode(value.rootIdentity),
            entryIdentity: try ManagedItemIdentityCodec.encode(value.entryIdentity),
            provenance: provenance,
            operationID: value.provenance.operationID.uuid.uuidString.lowercased(),
            verifiedAtMilliseconds: value.verifiedAtMilliseconds
        )
    }

    private static func distributionTarget(
        entry: DistributionTargetEntry,
        observation: DistributionTargetObservation
    ) throws -> SkillConsistencyAuditDistributionTarget {
        SkillConsistencyAuditDistributionTarget(
            scopeKey: entry.target.scope.targetScopeKey,
            scopeKind: entry.target.scope.kind,
            adapterCode: entry.target.scope.adapter?.storageKey,
            slug: entry.distributionSlug.value,
            slugKey: entry.slugKey,
            canonicalLocator: entry.canonicalLocator,
            observation: try targetObservation(observation)
        )
    }

    private static func targetObservation(
        _ value: DistributionTargetObservation
    ) throws -> SkillConsistencyAuditTargetObservation {
        switch value {
        case .missing:
            return .init(
                kind: "missing", skillID: nil, ssotDirectoryName: nil,
                copyState: nil, copyEvidence: nil
            )
        case .managed(let skillID, let directoryName):
            return .init(
                kind: "managed", skillID: skillID.directoryName,
                ssotDirectoryName: directoryName, copyState: nil, copyEvidence: nil
            )
        case .copy(let copy):
            return .init(
                kind: "copy", skillID: copy.evidence.skillID.directoryName,
                ssotDirectoryName: nil, copyState: copy.state.rawValue,
                copyEvidence: try copyEvidence(copy.evidence)
            )
        case .unknownObject:
            return .init(
                kind: "unknown_object", skillID: nil, ssotDirectoryName: nil,
                copyState: nil, copyEvidence: nil
            )
        case .unavailable:
            return .init(
                kind: "unavailable", skillID: nil, ssotDirectoryName: nil,
                copyState: nil, copyEvidence: nil
            )
        }
    }

    private static func copyEvidence(
        _ value: DistributionCopyConflictEvidence
    ) throws -> SkillConsistencyAuditCopyEvidence {
        SkillConsistencyAuditCopyEvidence(
            skillID: value.skillID.directoryName,
            baselineContent: value.baselineContentFingerprint.map(fingerprint),
            observedContent: value.observedContentFingerprint.map(fingerprint),
            baselinePhysicalTreeAlgorithmVersion: value.baselinePhysicalTreeDigest?.algorithmVersion,
            baselinePhysicalTreeDigest: value.baselinePhysicalTreeDigest?.digest,
            observedPhysicalTreeAlgorithmVersion: value.observedPhysicalTreeDigest?.algorithmVersion,
            observedPhysicalTreeDigest: value.observedPhysicalTreeDigest?.digest,
            baselineRootIdentity: try value.baselineRootIdentity.map(ManagedItemIdentityCodec.encode),
            observedRootIdentity: try value.observedRootIdentity.map(ManagedItemIdentityCodec.encode),
            baselineEntryIdentity: try value.baselineEntryIdentity.map(ManagedItemIdentityCodec.encode),
            observedEntryIdentity: try value.observedEntryIdentity.map(ManagedItemIdentityCodec.encode)
        )
    }

    private static func discoveryObservation(
        _ value: SkillDiscoveryObservation,
        attribution: SkillConsistencyAuditDistributionAttribution?
    ) throws -> SkillConsistencyAuditDiscoveryObservation {
        let roots = value.roots.map(discoveryRoot).sorted(by: discoveryRootPrecedes)
        let aliases = value.providerAliases.map {
            SkillConsistencyAuditProviderAlias(
                provider: $0.provider,
                identifier: $0.identifier
            )
        }.sorted {
            ($0.provider, $0.identifier) < ($1.provider, $1.identifier)
        }
        return SkillConsistencyAuditDiscoveryObservation(
            roots: roots,
            rootIdentity: try ManagedItemIdentityCodec.encode(value.rootIdentity),
            rawRelativeLocator: value.rawRelativeLocator,
            relativeLocator: value.relativeLocator,
            relativeLocatorKey: value.relativeLocatorKey,
            candidateIdentity: try value.candidateIdentity.map(ManagedItemIdentityCodec.encode),
            fingerprint: value.fingerprint.map(fingerprint),
            providerAliases: aliases,
            status: value.status.rawValue,
            reason: value.reason?.rawValue,
            matchedSkillID: value.matchedSkillID?.directoryName,
            matchedSourceKey: value.matchedSourceKey.map {
                SkillConsistencyAuditSourceKey(
                    repositoryURL: $0.repositoryURL,
                    subpath: $0.subpath
                )
            },
            managedDistributionTarget: attribution
        )
    }

    private static func attribution(
        for observation: SkillDiscoveryObservation,
        homeURL: URL,
        bindingsBySkillID: [SkillID: [DistributionBinding]],
        reconcileBySkillID: [SkillID: DistributionReconcileResult]
    ) -> SkillConsistencyAuditDistributionAttribution? {
        let bindings = bindingsBySkillID.values.flatMap { $0 }.sorted {
            if $0.skillID != $1.skillID {
                return skillIDPrecedes($0.skillID, $1.skillID)
            }
            return distributionBindingIntentPrecedes($0.intent, $1.intent)
        }
        for binding in bindings {
            guard let entry = DistributionTargetCatalog.current.entry(
                for: binding.scope,
                slug: binding.distributionSlug
            ),
            observationTargets(
                observation,
                binding: binding,
                expectedURL: absoluteTargetURL(entry: entry, homeURL: homeURL)
            ),
            let reconcile = reconcileBySkillID[binding.skillID],
            ownsTarget(reconcile.observations[entry], binding: binding) else {
                continue
            }
            return SkillConsistencyAuditDistributionAttribution(
                skillID: binding.skillID.directoryName,
                scopeKey: binding.scope.targetScopeKey,
                slug: binding.distributionSlug.value,
                syncMode: binding.syncMode.rawValue
            )
        }
        return nil
    }

    private static func observationTargets(
        _ observation: SkillDiscoveryObservation,
        binding: DistributionBinding,
        expectedURL: URL
    ) -> Bool {
        observation.roots.contains { root in
            guard discoveryScope(root.scope, matches: binding.scope) else { return false }
            let candidate = root.url.appendingPathComponent(
                observation.relativeLocator,
                isDirectory: true
            )
            return locator(candidate) == locator(expectedURL)
        }
    }

    private static func discoveryScope(
        _ discovery: SkillDiscoveryScope,
        matches binding: DistributionBindingScope
    ) -> Bool {
        switch binding {
        case .global:
            discovery.kind == .global
        case .agent(let platform):
            discovery.kind == .agent && discovery.adapterCode == platform.storageKey
        }
    }

    private static func ownsTarget(
        _ observation: DistributionTargetObservation?,
        binding: DistributionBinding
    ) -> Bool {
        switch (binding.syncMode, observation) {
        case (.symlink, .managed(let skillID, _)):
            skillID == binding.skillID
        case (.copy, .copy(let copy)):
            copy.state == .inSync && copy.evidence.skillID == binding.skillID
        default:
            false
        }
    }

    private static func discoveryRoot(
        _ value: SkillDiscoveryRoot
    ) -> SkillConsistencyAuditDiscoveryRoot {
        SkillConsistencyAuditDiscoveryRoot(
            scopeKey: value.scope.sortKey,
            kind: value.scope.kind.rawValue,
            adapterCode: value.scope.adapterCode,
            pathVariant: value.scope.pathVariant,
            customPathID: value.scope.customPathID?.uuidString.lowercased(),
            locator: locator(value.url)
        )
    }

    private static func absoluteTargetURL(
        entry: DistributionTargetEntry,
        homeURL: URL
    ) -> URL {
        homeURL.appendingPathComponent(
            String(entry.target.rootLocator.dropFirst(2)),
            isDirectory: true
        ).appendingPathComponent(entry.distributionSlug.value, isDirectory: true)
    }

    private static func fingerprint(
        _ value: SkillContentFingerprint
    ) -> SkillConsistencyAuditFingerprint {
        SkillConsistencyAuditFingerprint(
            algorithmVersion: value.algorithmVersion,
            digest: value.digest
        )
    }

    private static func bindingPrecedes(
        _ lhs: SkillConsistencyAuditBinding,
        _ rhs: SkillConsistencyAuditBinding
    ) -> Bool {
        (lhs.scopeKey, lhs.slugKey, lhs.slug) < (rhs.scopeKey, rhs.slugKey, rhs.slug)
    }

    private static func distributionTargetPrecedes(
        _ lhs: SkillConsistencyAuditDistributionTarget,
        _ rhs: SkillConsistencyAuditDistributionTarget
    ) -> Bool {
        (lhs.scopeKey, lhs.slugKey, lhs.slug) < (rhs.scopeKey, rhs.slugKey, rhs.slug)
    }

    private static func discoveryRootPrecedes(
        _ lhs: SkillConsistencyAuditDiscoveryRoot,
        _ rhs: SkillConsistencyAuditDiscoveryRoot
    ) -> Bool {
        (lhs.scopeKey, lhs.locator) < (rhs.scopeKey, rhs.locator)
    }

    private static func observedRootPrecedes(
        _ lhs: SkillConsistencyAuditObservedRoot,
        _ rhs: SkillConsistencyAuditObservedRoot
    ) -> Bool {
        if lhs.root != rhs.root {
            return discoveryRootPrecedes(lhs.root, rhs.root)
        }
        return lhs.identity.lexicographicallyPrecedes(rhs.identity)
    }

    private static func rootDiagnosticPrecedes(
        _ lhs: SkillConsistencyAuditRootDiagnostic,
        _ rhs: SkillConsistencyAuditRootDiagnostic
    ) -> Bool {
        (lhs.root.scopeKey, lhs.root.locator, lhs.reason)
            < (rhs.root.scopeKey, rhs.root.locator, rhs.reason)
    }

    private static func permissionError(_ code: Int32) -> Bool {
        code == EACCES || code == EPERM
    }
}
