import Foundation

nonisolated enum SkillConsistencyAuditCoverage: String, Codable, Sendable {
    case complete
    case incomplete
}

nonisolated enum SkillConsistencyAuditError: Error, Equatable, Sendable {
    case sourceChanged
    case inconsistentCatalog
    case permissionDenied
    case rootUnavailable
    case databaseUnavailable
    case writerUnavailable
}

nonisolated struct SkillConsistencyAuditPrepared: Sendable {
    let manifest: SkillConsistencyAuditManifest
    let canonicalBytes: Data
    let discoveryObservations: [SkillDiscoveryObservation]
}

nonisolated struct SkillConsistencyAuditManifest: Codable, Equatable, Sendable {
    let schema: String
    let coverage: SkillConsistencyAuditCoverage
    let health: [SkillConsistencyAuditHealth]
    let root: SkillConsistencyAuditManagedRoot
    let managedSkills: [SkillConsistencyAuditManagedSkill]
    let distributions: [SkillConsistencyAuditDistribution]
    let discovery: SkillConsistencyAuditDiscovery
}

nonisolated struct SkillConsistencyAuditHealth: Codable, Equatable, Sendable {
    let code: String
    let severity: String
    let subjectKind: String
    let subjectID: String
    let retryability: String
    let dataPreservation: String
    let recommendedActionCode: String
    let blocking: Bool
}

nonisolated struct SkillConsistencyAuditManagedRoot: Codable, Equatable, Sendable {
    let registeredLocator: String
    let canonicalLocator: String
    let identity: Data
}

nonisolated struct SkillConsistencyAuditFingerprint: Codable, Equatable, Sendable {
    let algorithmVersion: Int
    let digest: Data
}

nonisolated struct SkillConsistencyAuditManagedSkill: Codable, Equatable, Sendable {
    let skillID: String
    let revision: Int64
    let payload: Data
    let bindings: [SkillConsistencyAuditBinding]
}

nonisolated struct SkillConsistencyAuditBinding: Codable, Equatable, Sendable {
    let skillID: String
    let scopeKey: String
    let scopeKind: String
    let adapterCode: String?
    let slug: String
    let slugKey: String
    let syncMode: String
    let copyBaseline: SkillConsistencyAuditCopyBaseline?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64
}

nonisolated struct SkillConsistencyAuditCopyBaseline: Codable, Equatable, Sendable {
    let contentFingerprint: SkillConsistencyAuditFingerprint
    let physicalTreeAlgorithmVersion: Int
    let physicalTreeDigest: Data
    let rootIdentity: Data
    let entryIdentity: Data
    let provenance: String
    let operationID: String
    let verifiedAtMilliseconds: Int64
}

nonisolated struct SkillConsistencyAuditDistribution: Codable, Equatable, Sendable {
    let skillID: String
    let status: String
    let targets: [SkillConsistencyAuditDistributionTarget]
}

nonisolated struct SkillConsistencyAuditDistributionTarget: Codable, Equatable, Sendable {
    let scopeKey: String
    let scopeKind: String
    let adapterCode: String?
    let slug: String
    let slugKey: String
    let canonicalLocator: String
    let observation: SkillConsistencyAuditTargetObservation
}

nonisolated struct SkillConsistencyAuditTargetObservation: Codable, Equatable, Sendable {
    let kind: String
    let skillID: String?
    let ssotDirectoryName: String?
    let copyState: String?
    let copyEvidence: SkillConsistencyAuditCopyEvidence?
}

nonisolated struct SkillConsistencyAuditCopyEvidence: Codable, Equatable, Sendable {
    let skillID: String
    let baselineContent: SkillConsistencyAuditFingerprint?
    let observedContent: SkillConsistencyAuditFingerprint?
    let baselinePhysicalTreeAlgorithmVersion: Int?
    let baselinePhysicalTreeDigest: Data?
    let observedPhysicalTreeAlgorithmVersion: Int?
    let observedPhysicalTreeDigest: Data?
    let baselineRootIdentity: Data?
    let observedRootIdentity: Data?
    let baselineEntryIdentity: Data?
    let observedEntryIdentity: Data?
}

nonisolated struct SkillConsistencyAuditDiscovery: Codable, Equatable, Sendable {
    let roots: [SkillConsistencyAuditObservedRoot]
    let rootDiagnostics: [SkillConsistencyAuditRootDiagnostic]
    let observations: [SkillConsistencyAuditDiscoveryObservation]
}

nonisolated struct SkillConsistencyAuditObservedRoot: Codable, Equatable, Sendable {
    let root: SkillConsistencyAuditDiscoveryRoot
    let identity: Data
}

nonisolated struct SkillConsistencyAuditDiscoveryRoot: Codable, Equatable, Sendable {
    let scopeKey: String
    let kind: String
    let adapterCode: String?
    let pathVariant: String?
    let customPathID: String?
    let locator: String
}

nonisolated struct SkillConsistencyAuditRootDiagnostic: Codable, Equatable, Sendable {
    let root: SkillConsistencyAuditDiscoveryRoot
    let reason: String
}

nonisolated struct SkillConsistencyAuditProviderAlias: Codable, Equatable, Sendable {
    let provider: String
    let identifier: String
}

nonisolated struct SkillConsistencyAuditSourceKey: Codable, Equatable, Sendable {
    let repositoryURL: String
    let subpath: String
}

nonisolated struct SkillConsistencyAuditDistributionAttribution: Codable, Equatable, Sendable {
    let skillID: String
    let scopeKey: String
    let slug: String
    let syncMode: String
}

nonisolated struct SkillConsistencyAuditDiscoveryObservation: Codable, Equatable, Sendable {
    let roots: [SkillConsistencyAuditDiscoveryRoot]
    let rootIdentity: Data
    let rawRelativeLocator: String
    let relativeLocator: String
    let relativeLocatorKey: String
    let candidateIdentity: Data?
    let symbolicLinkIdentity: Data?
    let fingerprint: SkillConsistencyAuditFingerprint?
    let providerAliases: [SkillConsistencyAuditProviderAlias]
    let status: String
    let reason: String?
    let matchedSkillID: String?
    let matchedSourceKey: SkillConsistencyAuditSourceKey?
    let managedDistributionTarget: SkillConsistencyAuditDistributionAttribution?
}

nonisolated enum SkillConsistencyAuditManifestCodec {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
