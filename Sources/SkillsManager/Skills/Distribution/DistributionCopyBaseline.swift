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
    let contentFingerprint: SkillContentFingerprint
    let physicalTreeDigest: CopyPhysicalTreeDigest
    let rootIdentity: ManagedItemIdentity
    let entryIdentity: ManagedItemIdentity
    let appliedOperationID: SSOTOperationID
    let verifiedAtMilliseconds: Int64

    init(
        contentFingerprint: SkillContentFingerprint,
        physicalTreeDigest: CopyPhysicalTreeDigest,
        rootIdentity: ManagedItemIdentity,
        entryIdentity: ManagedItemIdentity,
        appliedOperationID: SSOTOperationID,
        verifiedAtMilliseconds: Int64
    ) throws {
        guard verifiedAtMilliseconds >= 0 else {
            throw DistributionBindingError.invalidCopyBaseline
        }
        self.contentFingerprint = contentFingerprint
        self.physicalTreeDigest = physicalTreeDigest
        self.rootIdentity = rootIdentity
        self.entryIdentity = entryIdentity
        self.appliedOperationID = appliedOperationID
        self.verifiedAtMilliseconds = verifiedAtMilliseconds
    }
}
