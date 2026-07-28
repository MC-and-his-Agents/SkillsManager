import Foundation

nonisolated enum CopyForkError: LocalizedError, Equatable, Sendable {
    case notCopy
    case notContentOnlyDrift
    case previewExpired
    case permissionDenied
    case unsafeContent
    case targetUnavailable
    case bindingConflict
    case operationInProgress
    case needsRepair

    var errorDescription: String? {
        switch self {
        case .notCopy: "The selected target is not a managed Copy."
        case .notContentOnlyDrift: "Only content-only Copy drift can be preserved as a Fork."
        case .previewExpired: "The Copy changed after the Fork preview was prepared."
        case .permissionDenied: "Skills Manager does not have permission to read the Copy."
        case .unsafeContent: "The Copy contains unsupported or unsafe content."
        case .targetUnavailable: "The Copy target is unavailable."
        case .bindingConflict: "The managed Copy binding changed concurrently."
        case .operationInProgress: "Another operation is already using this Skill or target."
        case .needsRepair: "The Copy Fork operation requires repair."
        }
    }
}

nonisolated struct CopyForkPreview: Equatable, Sendable {
    let operationID: SSOTOperationID
    let parentSkillID: SkillID
    let childSkillID: SkillID
    let scope: DistributionBindingScope
    let distributionSlug: DefaultDistributionSlug
    let contentFingerprint: SkillContentFingerprint
    let token: Data
}

nonisolated struct CopyForkResult: Equatable, Sendable {
    let operationID: SSOTOperationID
    let parentSkillID: SkillID
    let childSkillID: SkillID
    let scope: DistributionBindingScope
}

nonisolated struct CopyDriftDecisionPreview: Equatable, Sendable {
    let parentRevision: Int64
    let binding: DistributionBinding
    let observedEvidence: DistributionCopyEvidence
    let sourceEvidence: DistributionCopySourceEvidence
    let token: Data
    let forkPreview: CopyForkPreview
}

nonisolated struct CopyDriftDecisionPreviewWire: Codable, Equatable {
    let version: Int
    let forkPreviewToken: Data
    let absoluteSSOTTarget: String
    let ssotIdentity: Data
    let sourceContent: DistributionFingerprintWireV2
    let sourcePhysicalTree: DistributionTreeDigestWireV2

    init(
        forkPreviewToken: Data,
        sourceEvidence: DistributionCopySourceEvidence
    ) throws {
        version = 1
        self.forkPreviewToken = forkPreviewToken
        absoluteSSOTTarget = sourceEvidence.absoluteTarget
        ssotIdentity = try ManagedItemIdentityCodec.encode(sourceEvidence.ssotIdentity)
        sourceContent = DistributionFingerprintWireV2(
            sourceEvidence.contentFingerprint
        )
        sourcePhysicalTree = DistributionTreeDigestWireV2(
            sourceEvidence.physicalTreeDigest
        )
    }

    func canonicalData() throws -> Data {
        try DistributionOperationPayloadCodec.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try DistributionOperationPayloadCodec.decode(Self.self, from: data)
        guard value.version == 1 else { throw CopyForkError.previewExpired }
        return value
    }
}

nonisolated enum CopyForkOperationPhase: String, Sendable {
    case reserved
    case childCreated
    case completed
}

nonisolated enum CopyForkOperationOutcome: String, Sendable {
    case applied
    case needsRepair
}

nonisolated struct CopyForkOperationRecord: Equatable, Sendable {
    let operationID: SSOTOperationID
    let parentSkillID: SkillID
    let childSkillID: SkillID
    let parentRevision: Int64
    let parentBinding: DistributionBinding
    let observedEvidence: DistributionCopyEvidence
    let previewPayload: Data
    let phase: CopyForkOperationPhase
    let outcome: CopyForkOperationOutcome?
    let verifiedAtMilliseconds: Int64?
    let attemptCount: Int64
    let lastError: String?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    var isActive: Bool { outcome == nil || outcome == .needsRepair }
}

nonisolated struct CopyForkPreviewWire: Codable, Equatable {
    let version: Int
    let operationID: UUID
    let childWriteOperationID: UUID
    let parentSkillID: UUID
    let childSkillID: UUID
    let parentRevision: Int64
    let scopeKind: String
    let adapterCode: String?
    let distributionSlug: String
    let childDisplayName: String
    let childDefaultDistributionSlug: String
    let parentBaseline: Baseline
    let observed: Evidence
    let createdAtMilliseconds: Int64

    struct Baseline: Codable, Equatable {
        let contentAlgorithmVersion: Int
        let contentFingerprint: Data
        let treeAlgorithmVersion: Int
        let treeDigest: Data
        let rootIdentity: Data
        let entryIdentity: Data
        let provenanceKind: String
        let provenanceOperationID: UUID
        let verifiedAtMilliseconds: Int64
        let bindingCreatedAtMilliseconds: Int64
        let bindingUpdatedAtMilliseconds: Int64
    }

    struct Evidence: Codable, Equatable {
        let contentAlgorithmVersion: Int
        let contentFingerprint: Data
        let treeAlgorithmVersion: Int
        let treeDigest: Data
        let rootIdentity: Data
        let entryIdentity: Data
    }

    func canonicalData() throws -> Data {
        try DistributionOperationPayloadCodec.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try DistributionOperationPayloadCodec.decode(Self.self, from: data)
        guard value.version == 1 else { throw CopyForkError.previewExpired }
        return value
    }
}
