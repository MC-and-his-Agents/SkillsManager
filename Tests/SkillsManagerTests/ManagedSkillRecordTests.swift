import Foundation
import Testing
@testable import SkillsManager

@Suite("Managed skill catalog record")
struct ManagedSkillRecordTests {
    @Test("keeps stable identity across presentation changes")
    func stableIdentity() throws {
        let skillID = SkillID(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
        let fingerprint = try SkillContentFingerprint(currentDigest: Data(repeating: 0xab, count: 32))
        let originalName = try SkillDisplayName("Original")
        let renamed = try SkillDisplayName("Renamed")

        let original = try ManagedSkillRecord(
            skillID: skillID,
            displayName: originalName,
            defaultDistributionSlug: DefaultDistributionSlug(candidateFrom: originalName),
            contentFingerprint: fingerprint,
            createdAtMilliseconds: 10,
            updatedAtMilliseconds: 10
        )
        let updated = try ManagedSkillRecord(
            skillID: skillID,
            displayName: renamed,
            defaultDistributionSlug: DefaultDistributionSlug(candidateFrom: renamed),
            contentFingerprint: fingerprint,
            status: .needsRepair,
            createdAtMilliseconds: 10,
            updatedAtMilliseconds: 20
        )

        #expect(original.skillID == updated.skillID)
        #expect(original.defaultDistributionSlug.value == "Original")
        #expect(updated.defaultDistributionSlug.value == "Renamed")
        #expect(updated.status == .needsRepair)
        #expect(updated.fingerprintAlgorithmVersion == SkillContentSnapshot.fingerprintAlgorithmVersion)
    }

    @Test("rejects invalid fingerprints and timestamps")
    func invalidValues() throws {
        #expect(throws: ManagedSkillRecordError.invalidFingerprintLength(31)) {
            try SkillContentFingerprint(algorithmVersion: 1, digest: Data(repeating: 0, count: 31))
        }

        let name = try SkillDisplayName("Skill")
        let fingerprint = try SkillContentFingerprint(currentDigest: Data(repeating: 0, count: 32))
        #expect(throws: ManagedSkillRecordError.invalidTimestampRange) {
            try ManagedSkillRecord(
                displayName: name,
                defaultDistributionSlug: DefaultDistributionSlug(candidateFrom: name),
                contentFingerprint: fingerprint,
                createdAtMilliseconds: 1,
                updatedAtMilliseconds: 0
            )
        }
    }

    @Test("preserves explicit v1 and rejects old or unsupported algorithms")
    func fingerprintAlgorithmSemantics() throws {
        let digest = Data(repeating: 0xcd, count: 32)
        let current = try SkillContentFingerprint(currentDigest: digest)
        let restoredV1 = try SkillContentFingerprint(algorithmVersion: 1, digest: digest)

        #expect(current.algorithmVersion == SkillContentSnapshot.fingerprintAlgorithmVersion)
        #expect(restoredV1.algorithmVersion == 1)
        #expect(restoredV1.digest == digest)
        #expect(throws: ManagedSkillRecordError.unsupportedFingerprintAlgorithmVersion(0)) {
            try SkillContentFingerprint(algorithmVersion: 0, digest: digest)
        }
        #expect(throws: ManagedSkillRecordError.unsupportedFingerprintAlgorithmVersion(2)) {
            try SkillContentFingerprint(algorithmVersion: 2, digest: digest)
        }
    }
}
