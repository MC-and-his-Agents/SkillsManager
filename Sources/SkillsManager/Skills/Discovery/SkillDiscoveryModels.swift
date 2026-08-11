import Foundation

nonisolated enum SkillDiscoveryScopeKind: String, Hashable, Sendable {
    case global
    case agent
    case custom
}

nonisolated struct SkillDiscoveryScope: Hashable, Sendable {
    let kind: SkillDiscoveryScopeKind
    let adapterCode: String?
    let pathVariant: String?
    let customPathID: UUID?

    private init(
        kind: SkillDiscoveryScopeKind,
        adapterCode: String?,
        pathVariant: String?,
        customPathID: UUID?
    ) {
        self.kind = kind
        self.adapterCode = adapterCode
        self.pathVariant = pathVariant
        self.customPathID = customPathID
    }

    static let global = SkillDiscoveryScope(
        kind: .global,
        adapterCode: nil,
        pathVariant: nil,
        customPathID: nil
    )

    static func agent(adapterCode: String, pathVariant: String) -> SkillDiscoveryScope {
        SkillDiscoveryScope(
            kind: .agent,
            adapterCode: adapterCode,
            pathVariant: pathVariant,
            customPathID: nil
        )
    }

    static func custom(
        pathID: UUID,
        adapterCode: String,
        pathVariant: String
    ) -> SkillDiscoveryScope {
        SkillDiscoveryScope(
            kind: .custom,
            adapterCode: adapterCode,
            pathVariant: pathVariant,
            customPathID: pathID
        )
    }

    var sortKey: String {
        [
            kind.rawValue,
            customPathID?.uuidString.lowercased() ?? "",
            adapterCode ?? "",
            pathVariant ?? "",
        ].joined(separator: "\u{0}")
    }
}

nonisolated struct SkillDiscoveryRoot: Hashable, Sendable {
    let scope: SkillDiscoveryScope
    let url: URL
    let diagnostic: SkillDiscoveryReason?

    init(
        scope: SkillDiscoveryScope,
        url: URL,
        diagnostic: SkillDiscoveryReason? = nil
    ) {
        self.scope = scope
        self.url = url
        self.diagnostic = diagnostic
    }
}

nonisolated enum SkillDiscoveryStatus: String, Hashable, Sendable {
    case managed
    case claimable
    case unmanaged
    case conflict
    case permissionDenied
    case damaged
}

nonisolated enum SkillDiscoveryReason: String, Hashable, Sendable {
    case rootPermissionDenied
    case rootChanged
    case rootUnsupportedType
    case rootReadFailed
    case unknownSymlink
    case symbolicLinkTargetUnavailable
    case symbolicLinkTargetUnsupported
    case candidatePermissionDenied
    case sourceChanged
    case missingSkillManifest
    case containerDirectory
    case invalidSkillManifest
    case unsupportedEntryType
    case unsafeContent
    case resourceLimitExceeded
    case candidateReadFailed
    case ambiguousLocalAssociation
    case localAssociationDrift
    case ambiguousSource
    case ambiguousFingerprint
    case evidenceConflict
    case scopeSlugConflict
}

nonisolated struct SkillDiscoverySourceKey: Hashable, Sendable {
    let repositoryURL: String
    let subpath: String

    init(repositoryURL: String, subpath: String) {
        self.repositoryURL = repositoryURL
        self.subpath = subpath
    }

    init(_ source: SkillSourceRecord) {
        repositoryURL = source.repositoryURL.value
        subpath = source.subpath.value
    }
}

nonisolated struct SkillDiscoveryManagedSkill: Hashable, Sendable {
    let skillID: SkillID
    let fingerprint: SkillContentFingerprint
    let sourceKey: SkillDiscoverySourceKey?
    let providerAliases: Set<ProviderAliasIdentity>
    let providerProvenanceAliases: Set<ProviderAliasIdentity>

    init(
        skillID: SkillID,
        fingerprint: SkillContentFingerprint,
        sourceKey: SkillDiscoverySourceKey?,
        providerAliases: Set<ProviderAliasIdentity>,
        providerProvenanceAliases: Set<ProviderAliasIdentity> = []
    ) {
        self.skillID = skillID
        self.fingerprint = fingerprint
        self.sourceKey = sourceKey
        self.providerAliases = providerAliases
        self.providerProvenanceAliases = providerProvenanceAliases
    }
}

nonisolated struct SkillDiscoveryLocalAssociation: Hashable, Sendable {
    let scope: SkillDiscoveryScope
    let relativeLocatorKey: String
    let skillID: SkillID
    let fingerprint: SkillContentFingerprint
}

nonisolated struct SkillDiscoveryCatalog: Sendable {
    static let empty = SkillDiscoveryCatalog()

    let managedSkills: [SkillDiscoveryManagedSkill]
    let localAssociations: [SkillDiscoveryLocalAssociation]

    init(
        managedSkills: [SkillDiscoveryManagedSkill] = [],
        localAssociations: [SkillDiscoveryLocalAssociation] = []
    ) {
        self.managedSkills = managedSkills
        self.localAssociations = localAssociations
    }
}

nonisolated struct SkillDiscoveryRootDiagnostic: Hashable, Sendable {
    let root: SkillDiscoveryRoot
    let reason: SkillDiscoveryReason
}

nonisolated struct SkillDiscoveryObservedRoot: Hashable, Sendable {
    let root: SkillDiscoveryRoot
    let identity: ManagedItemIdentity
}

nonisolated struct SkillDiscoveryObservation: Hashable, Sendable {
    let roots: [SkillDiscoveryRoot]
    let rootIdentity: ManagedItemIdentity
    let rawRelativeLocator: String
    let relativeLocator: String
    let relativeLocatorKey: String
    let candidateIdentity: ManagedItemIdentity?
    let symbolicLinkIdentity: ManagedItemIdentity?
    let locationRevision: SkillDiscoveryLocationRevision?
    let fingerprint: SkillContentFingerprint?
    let providerAliases: Set<ProviderAliasIdentity>
    let status: SkillDiscoveryStatus
    let reason: SkillDiscoveryReason?
    let matchedSkillID: SkillID?
    let matchedSourceKey: SkillDiscoverySourceKey?

    init(
        roots: [SkillDiscoveryRoot],
        rootIdentity: ManagedItemIdentity,
        rawRelativeLocator: String,
        relativeLocator: String,
        relativeLocatorKey: String,
        candidateIdentity: ManagedItemIdentity?,
        symbolicLinkIdentity: ManagedItemIdentity?,
        locationRevision: SkillDiscoveryLocationRevision? = nil,
        fingerprint: SkillContentFingerprint?,
        providerAliases: Set<ProviderAliasIdentity>,
        status: SkillDiscoveryStatus,
        reason: SkillDiscoveryReason?,
        matchedSkillID: SkillID?,
        matchedSourceKey: SkillDiscoverySourceKey?
    ) {
        self.roots = roots
        self.rootIdentity = rootIdentity
        self.rawRelativeLocator = rawRelativeLocator
        self.relativeLocator = relativeLocator
        self.relativeLocatorKey = relativeLocatorKey
        self.candidateIdentity = candidateIdentity
        self.symbolicLinkIdentity = symbolicLinkIdentity
        self.locationRevision = locationRevision
        self.fingerprint = fingerprint
        self.providerAliases = providerAliases
        self.status = status
        self.reason = reason
        self.matchedSkillID = matchedSkillID
        self.matchedSourceKey = matchedSourceKey
    }

    var scopes: [SkillDiscoveryScope] {
        roots.map(\.scope)
    }

    var displayURLs: [URL] {
        roots.map { $0.url.appendingPathComponent(relativeLocator, isDirectory: true) }
    }
}

nonisolated struct SkillDiscoveryResult: Sendable {
    let observedRoots: [SkillDiscoveryObservedRoot]
    let observations: [SkillDiscoveryObservation]
    let rootDiagnostics: [SkillDiscoveryRootDiagnostic]
}

nonisolated struct SkillDiscoveryRootPlan {
    static func make(
        homeURL: URL,
        customPaths: [CustomSkillPath],
        catalog: DistributionTargetCatalog? = nil
    ) -> [SkillDiscoveryRoot] {
        let catalog = catalog ?? DistributionTargetCatalog.current(homeURL: homeURL)
        var roots = [
            SkillDiscoveryRoot(
                scope: .global,
                url: catalog.globalTarget.resolvedRootURL
                    ?? homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
            ),
        ]
        for platform in SkillPlatform.allCases {
            guard let target = catalog.target(for: .agent(platform)) else { continue }
            let primaryURL = target.resolvedRootURL
                ?? homeURL.appendingPathComponent(platform.relativePath, isDirectory: true)
            roots.append(SkillDiscoveryRoot(
                scope: .agent(
                    adapterCode: platform.storageKey,
                    pathVariant: target.rootLocator.hasPrefix("~")
                        ? platform.relativePath
                        : target.rootLocator
                ),
                url: primaryURL.standardizedFileURL,
                diagnostic: target.resolutionStatus.flatMap(Self.rootDiagnostic)
            ))
            for compatibility in platform.discoveryCompatibilityRelativePaths {
                let isNestedCompatibility = compatibility.hasPrefix(
                    platform.dedicatedDistributionRelativePath + "/"
                )
                let suffix = isNestedCompatibility
                    ? String(compatibility.dropFirst(
                        platform.dedicatedDistributionRelativePath.count + 1
                    ))
                    : ""
                let compatibilityURL = isNestedCompatibility
                    ? primaryURL.appendingPathComponent(suffix, isDirectory: true)
                    : homeURL.appendingPathComponent(compatibility, isDirectory: true)
                roots.append(SkillDiscoveryRoot(
                    scope: .agent(
                        adapterCode: platform.storageKey,
                        pathVariant: target.rootLocator.hasPrefix("~") || !isNestedCompatibility
                            ? compatibility
                            : "\(target.rootLocator)/\(suffix)"
                    ),
                    url: compatibilityURL.standardizedFileURL,
                    diagnostic: target.resolutionStatus.flatMap(Self.rootDiagnostic)
                ))
            }
        }
        for customPath in customPaths {
            switch customPath.mode {
            case .project:
                roots.append(contentsOf: platformRoots(in: customPath.url) { platform, relativePath in
                    .custom(
                        pathID: customPath.id,
                        adapterCode: platform.storageKey,
                        pathVariant: relativePath
                    )
                })
            case .collection(let adapter):
                roots.append(SkillDiscoveryRoot(
                    scope: .custom(
                        pathID: customPath.id,
                        adapterCode: adapter.storageKey,
                        pathVariant: CustomSkillPathMode.directPathVariant
                    ),
                    url: customPath.url.standardizedFileURL
                ))
            }
        }
        var seen: Set<String> = []
        return roots.filter { root in
            let key = [
                root.url.standardizedFileURL.path,
                root.scope.sortKey,
                root.diagnostic?.rawValue ?? "",
            ].joined(separator: "\u{0}")
            return seen.insert(key).inserted
        }
    }

    private static func platformRoots(
        in baseURL: URL,
        scope: (SkillPlatform, String) -> SkillDiscoveryScope
    ) -> [SkillDiscoveryRoot] {
        SkillPlatform.allCases.flatMap { platform in
            platform.relativePaths.map { relativePath in
                SkillDiscoveryRoot(
                    scope: scope(platform, relativePath),
                    url: baseURL.appendingPathComponent(relativePath, isDirectory: true)
                )
            }
        }
    }

    private static func rootDiagnostic(
        _ status: HarnessSkillRootResolutionStatus
    ) -> SkillDiscoveryReason? {
        switch status {
        case .changed: .rootChanged
        case .permissionDenied: .rootPermissionDenied
        case .unsupported: .rootUnsupportedType
        case .unavailable, .environmentUnavailable, .conflict: .rootReadFailed
        case .default, .configured, .environmentHint: nil
        }
    }
}
