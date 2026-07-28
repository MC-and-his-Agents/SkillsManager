import Foundation

nonisolated struct CopyPhysicalTreeDigest: Hashable, Sendable {
    static let algorithmVersion = 1

    let algorithmVersion: Int
    let digest: Data

    init(algorithmVersion: Int = Self.algorithmVersion, digest: Data) throws {
        guard algorithmVersion == Self.algorithmVersion, digest.count == 32 else {
            throw DistributionBindingError.invalidCopyBaseline
        }
        self.algorithmVersion = algorithmVersion
        self.digest = digest
    }
}

nonisolated struct DistributionCopyBaseline: Hashable, Sendable {
    enum Provenance: Hashable, Sendable {
        case distribution(SSOTOperationID)
        case copyFork(SSOTOperationID)

        var operationID: SSOTOperationID {
            switch self {
            case .distribution(let operationID), .copyFork(let operationID):
                operationID
            }
        }
    }

    let contentFingerprint: SkillContentFingerprint
    let physicalTreeDigest: CopyPhysicalTreeDigest
    let rootIdentity: ManagedItemIdentity
    let entryIdentity: ManagedItemIdentity
    let provenance: Provenance
    let verifiedAtMilliseconds: Int64

    init(
        contentFingerprint: SkillContentFingerprint,
        physicalTreeDigest: CopyPhysicalTreeDigest,
        rootIdentity: ManagedItemIdentity,
        entryIdentity: ManagedItemIdentity,
        appliedOperationID: SSOTOperationID,
        verifiedAtMilliseconds: Int64
    ) throws {
        try self.init(
            contentFingerprint: contentFingerprint,
            physicalTreeDigest: physicalTreeDigest,
            rootIdentity: rootIdentity,
            entryIdentity: entryIdentity,
            provenance: .distribution(appliedOperationID),
            verifiedAtMilliseconds: verifiedAtMilliseconds
        )
    }

    init(
        contentFingerprint: SkillContentFingerprint,
        physicalTreeDigest: CopyPhysicalTreeDigest,
        rootIdentity: ManagedItemIdentity,
        entryIdentity: ManagedItemIdentity,
        provenance: Provenance,
        verifiedAtMilliseconds: Int64
    ) throws {
        guard verifiedAtMilliseconds >= 0 else {
            throw DistributionBindingError.invalidCopyBaseline
        }
        self.contentFingerprint = contentFingerprint
        self.physicalTreeDigest = physicalTreeDigest
        self.rootIdentity = rootIdentity
        self.entryIdentity = entryIdentity
        self.provenance = provenance
        self.verifiedAtMilliseconds = verifiedAtMilliseconds
    }

    var appliedOperationID: SSOTOperationID { provenance.operationID }
}
