import Foundation
import Testing

@testable import SkillsManager

@Suite("Provider provenance")
struct ProviderProvenanceTests {
    @Test("requires canonical slug value and collision key")
    func validatesCanonicalLocator() throws {
        let skillID = SkillID()
        let canonical = try DefaultDistributionSlug(validating: "Résumé")
        let identity = try ProviderAliasIdentity(
            provider: "clawdhub",
            identifier: canonical.value
        )
        let record = try ProviderProvenanceRecord(
            skillID: skillID,
            identity: identity,
            identifierKey: canonical.collisionKey,
            version: try SourceVersion("1.0.0")
        )
        #expect(record.identifierKey == canonical.collisionKey)

        let decomposed = try ProviderAliasIdentity(
            provider: "clawdhub",
            identifier: "Re\u{301}sume\u{301}"
        )
        #expect(throws: ProviderProvenanceError.invalidIdentifier) {
            _ = try ProviderProvenanceRecord(
                skillID: skillID,
                identity: decomposed,
                identifierKey: canonical.collisionKey
            )
        }
        #expect(throws: ProviderProvenanceError.invalidIdentifierKey) {
            _ = try ProviderProvenanceRecord(
                skillID: skillID,
                identity: identity,
                identifierKey: "wrong"
            )
        }
    }

    @Test("payload rejects cross-Skill, duplicate provider and excessive records")
    func validatesPayloadRelationships() throws {
        let skill = try provenanceSkill()
        let first = try provenance(
            skillID: skill.skillID,
            provider: "clawdhub",
            slug: "first"
        )
        let duplicateProvider = try provenance(
            skillID: skill.skillID,
            provider: "clawdhub",
            slug: "second"
        )
        #expect(throws: SSOTWritePayloadError.duplicateProviderProvenance) {
            _ = try SSOTSkillWritePayload(
                skill: skill,
                providerProvenance: [first, duplicateProvider]
            )
        }
        #expect(throws: SSOTWritePayloadError.providerProvenanceSkillMismatch) {
            _ = try SSOTSkillWritePayload(
                skill: skill,
                providerProvenance: [
                    try provenance(skillID: SkillID(), provider: "clawdhub", slug: "first"),
                ]
            )
        }
        let excessive = try (0...SSOTSkillWritePayload.maximumProviderProvenanceCount).map {
            try provenance(skillID: skill.skillID, provider: "provider\($0)", slug: "skill-\($0)")
        }
        #expect(throws: SSOTWritePayloadError.tooManyProviderProvenance) {
            _ = try SSOTSkillWritePayload(skill: skill, providerProvenance: excessive)
        }
    }
}

private func provenance(
    skillID: SkillID,
    provider: String,
    slug rawSlug: String
) throws -> ProviderProvenanceRecord {
    let slug = try DefaultDistributionSlug(validating: rawSlug)
    return try ProviderProvenanceRecord(
        skillID: skillID,
        identity: ProviderAliasIdentity(provider: provider, identifier: slug.value),
        identifierKey: slug.collisionKey
    )
}

private func provenanceSkill() throws -> ManagedSkillRecord {
    try ManagedSkillRecord(
        skillID: SkillID(),
        displayName: SkillDisplayName("Sample"),
        defaultDistributionSlug: DefaultDistributionSlug(validating: "sample"),
        contentFingerprint: SkillContentFingerprint(currentDigest: Data(repeating: 1, count: 32)),
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
}
