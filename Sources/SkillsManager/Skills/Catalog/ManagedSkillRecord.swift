import Foundation

nonisolated enum ManagedSkillStatus: String, CaseIterable, Sendable {
    case managed
    case needsRepair
}

nonisolated enum ManagedSkillRecordError: Error, Equatable {
    case unsupportedFingerprintAlgorithmVersion(Int)
    case invalidFingerprintLength(Int)
    case invalidTimestampRange
}

nonisolated struct SkillContentFingerprint: Hashable, Sendable {
    let algorithmVersion: Int
    let digest: Data

    init(currentDigest digest: Data) throws {
        try self.init(
            algorithmVersion: SkillContentSnapshot.fingerprintAlgorithmVersion,
            digest: digest
        )
    }

    init(algorithmVersion: Int, digest: Data) throws {
        guard algorithmVersion == 1 else {
            throw ManagedSkillRecordError.unsupportedFingerprintAlgorithmVersion(algorithmVersion)
        }
        guard digest.count == 32 else {
            throw ManagedSkillRecordError.invalidFingerprintLength(digest.count)
        }
        self.algorithmVersion = algorithmVersion
        self.digest = digest
    }
}

nonisolated struct ManagedSkillRecord: Hashable, Sendable {
    let skillID: SkillID
    let displayName: SkillDisplayName
    let defaultDistributionSlug: DefaultDistributionSlug
    let contentFingerprint: SkillContentFingerprint
    let status: ManagedSkillStatus
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    var fingerprintAlgorithmVersion: Int { contentFingerprint.algorithmVersion }

    init(
        skillID: SkillID = SkillID(),
        displayName: SkillDisplayName,
        defaultDistributionSlug: DefaultDistributionSlug,
        contentFingerprint: SkillContentFingerprint,
        status: ManagedSkillStatus = .managed,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) throws {
        guard createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds else {
            throw ManagedSkillRecordError.invalidTimestampRange
        }
        self.skillID = skillID
        self.displayName = displayName
        self.defaultDistributionSlug = defaultDistributionSlug
        self.contentFingerprint = contentFingerprint
        self.status = status
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }
}
