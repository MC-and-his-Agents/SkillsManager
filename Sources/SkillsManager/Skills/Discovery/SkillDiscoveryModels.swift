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
    case candidatePermissionDenied
    case sourceChanged
    case missingSkillManifest
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

nonisolated struct SkillDiscoveryObservation: Hashable, Sendable {
    let roots: [SkillDiscoveryRoot]
    let relativeLocator: String
    let relativeLocatorKey: String
    let candidateIdentity: ManagedItemIdentity?
    let fingerprint: SkillContentFingerprint?
    let providerAliases: Set<ProviderAliasIdentity>
    let status: SkillDiscoveryStatus
    let reason: SkillDiscoveryReason?
    let matchedSkillID: SkillID?
    let matchedSourceKey: SkillDiscoverySourceKey?

    var scopes: [SkillDiscoveryScope] {
        roots.map(\.scope)
    }

    var displayURLs: [URL] {
        roots.map { $0.url.appendingPathComponent(relativeLocator, isDirectory: true) }
    }
}

nonisolated struct SkillDiscoveryResult: Sendable {
    let observations: [SkillDiscoveryObservation]
    let rootDiagnostics: [SkillDiscoveryRootDiagnostic]
}

nonisolated struct SkillDiscoveryRootPlan {
    static func make(homeURL: URL, customPaths: [CustomSkillPath]) -> [SkillDiscoveryRoot] {
        var roots = [
            SkillDiscoveryRoot(
                scope: .global,
                url: homeURL.appendingPathComponent(".agents/skills", isDirectory: true)
            ),
        ]
        roots.append(contentsOf: platformRoots(in: homeURL, scope: { platform, relativePath in
            .agent(adapterCode: platform.storageKey, pathVariant: relativePath)
        }))
        for customPath in customPaths {
            roots.append(contentsOf: platformRoots(in: customPath.url) { platform, relativePath in
                .custom(
                    pathID: customPath.id,
                    adapterCode: platform.storageKey,
                    pathVariant: relativePath
                )
            })
        }
        return roots
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
}
