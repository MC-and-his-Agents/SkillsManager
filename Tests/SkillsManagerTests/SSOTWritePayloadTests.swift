import Foundation
import Testing

@testable import SkillsManager

@Suite("SSOT journal domain payload")
struct SSOTWritePayloadTests {
    @Test("round-trips the complete Skill domain state deterministically")
    func completeRoundTrip() throws {
        let payload = try makePayload()

        let firstEncoding = try SSOTWritePayloadCodec.encode(payload)
        let secondEncoding = try SSOTWritePayloadCodec.encode(payload)
        let decoded = try SSOTWritePayloadCodec.decode(firstEncoding)

        #expect(firstEncoding == secondEncoding)
        #expect(decoded.skill == payload.skill)
        #expect(decoded.source == payload.source)
        #expect(decoded.providerAliases == payload.providerAliases)
        #expect(decoded.localOrigins == payload.localOrigins)
    }

    @Test("decodes legacy v1 payloads without local origins")
    func decodesLegacyV1() throws {
        let payload = try makePayload(includeLocalOrigins: false)
        var legacyEnvelope = try #require(
            JSONSerialization.jsonObject(
                with: SSOTWritePayloadCodec.encode(payload)
            ) as? [String: Any]
        )
        legacyEnvelope["version"] = 1
        legacyEnvelope.removeValue(forKey: "localOrigins")

        let decoded = try SSOTWritePayloadCodec.decode(
            JSONSerialization.data(withJSONObject: legacyEnvelope)
        )

        #expect(decoded.skill == payload.skill)
        #expect(decoded.source == payload.source)
        #expect(decoded.providerAliases == payload.providerAliases)
        #expect(decoded.localOrigins.isEmpty)
    }

    @Test("rejects source and Provider aliases outside the Skill domain")
    func rejectsMismatchedRelationships() throws {
        let payload = try makePayload()
        let otherSkill = SkillID()
        let mismatchedSource = SkillSourceRecord(
            skillID: otherSkill,
            repositoryURL: try NormalizedRepositoryURL("https://github.com/example/skills"),
            subpath: try RepositorySubpath("sample")
        )
        #expect(throws: SSOTWritePayloadError.sourceSkillMismatch) {
            _ = try SSOTSkillWritePayload(skill: payload.skill, source: mismatchedSource)
        }

        let otherSource = SourceID()
        let mismatchedAlias = ProviderAliasRecord(
            sourceID: otherSource,
            identity: try ProviderAliasIdentity(provider: "skills.sh", identifier: "example/sample")
        )
        #expect(throws: SSOTWritePayloadError.aliasSourceMismatch) {
            _ = try SSOTSkillWritePayload(
                skill: payload.skill,
                source: payload.source,
                providerAliases: [mismatchedAlias]
            )
        }
    }

    @Test("rejects duplicate aliases, excessive aliases and invalid encodings")
    func rejectsInvalidPayloads() throws {
        let payload = try makePayload()
        let alias = try #require(payload.providerAliases.first)
        #expect(throws: SSOTWritePayloadError.duplicateProviderAlias) {
            _ = try SSOTSkillWritePayload(
                skill: payload.skill,
                source: payload.source,
                providerAliases: [alias, alias]
            )
        }

        let aliases = try (0...SSOTSkillWritePayload.maximumProviderAliasCount).map { index in
            ProviderAliasRecord(
                sourceID: try #require(payload.source).sourceID,
                identity: try ProviderAliasIdentity(
                    provider: "provider",
                    identifier: "skill-\(index)"
                )
            )
        }
        #expect(throws: SSOTWritePayloadError.tooManyProviderAliases) {
            _ = try SSOTSkillWritePayload(
                skill: payload.skill,
                source: payload.source,
                providerAliases: aliases
            )
        }

        #expect(throws: SSOTWritePayloadError.payloadTooLarge) {
            _ = try SSOTWritePayloadCodec.decode(Data())
        }
        #expect(throws: SSOTWritePayloadError.invalidPayload) {
            _ = try SSOTWritePayloadCodec.decode(Data("not-json".utf8))
        }
        var futureEnvelope = try #require(
            JSONSerialization.jsonObject(
                with: SSOTWritePayloadCodec.encode(payload)
            ) as? [String: Any]
        )
        futureEnvelope["version"] = 3
        #expect(throws: SSOTWritePayloadError.unsupportedVersion(3)) {
            _ = try SSOTWritePayloadCodec.decode(
                JSONSerialization.data(withJSONObject: futureEnvelope)
            )
        }
        #expect(throws: SSOTWritePayloadError.payloadTooLarge) {
            _ = try SSOTWritePayloadCodec.decode(
                Data(repeating: 0, count: SSOTWritePayloadCodec.maximumEncodedByteCount + 1)
            )
        }
    }
}

private func makePayload(includeLocalOrigins: Bool = true) throws -> SSOTSkillWritePayload {
    let skillID = SkillID(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
    let sourceID = SourceID(UUID(uuidString: "11223344-5566-7788-99aa-bbccddeeff00")!)
    let displayName = try SkillDisplayName("Sample Skill")
    let skill = try ManagedSkillRecord(
        skillID: skillID,
        displayName: displayName,
        defaultDistributionSlug: DefaultDistributionSlug(candidateFrom: displayName),
        contentFingerprint: SkillContentFingerprint(
            currentDigest: Data(repeating: 0xab, count: 32)
        ),
        status: .managed,
        createdAtMilliseconds: 100,
        updatedAtMilliseconds: 200
    )
    let source = SkillSourceRecord(
        sourceID: sourceID,
        skillID: skillID,
        repositoryURL: try NormalizedRepositoryURL("https://github.com/example/skills.git"),
        subpath: try RepositorySubpath("sample"),
        revision: try SourceRevision("abc123"),
        version: try SourceVersion("1.0.0"),
        downloadURL: try PublicDownloadURL("https://example.com/sample.zip")
    )
    let aliases = [
        ProviderAliasRecord(
            sourceID: sourceID,
            identity: try ProviderAliasIdentity(provider: "skills.sh", identifier: "example/sample")
        ),
        ProviderAliasRecord(
            sourceID: sourceID,
            identity: try ProviderAliasIdentity(provider: "clawdhub", identifier: "sample")
        ),
    ]
    let localOrigins: [LocalSkillOriginRecord] = if includeLocalOrigins {
        try [
            LocalSkillOriginRecord(
                skillID: skillID,
                scope: .global,
                rawLocator: "Sample",
                normalizedLocator: "Sample",
                collisionKey: SkillContentPath.collisionKey(for: "Sample"),
                fingerprint: skill.contentFingerprint,
                confirmedAtMilliseconds: 300
            ),
            LocalSkillOriginRecord(
                skillID: skillID,
                scope: .agent(adapterCode: "codex", pathVariant: ".codex/skills"),
                rawLocator: "Sample",
                normalizedLocator: "Sample",
                collisionKey: SkillContentPath.collisionKey(for: "Sample"),
                fingerprint: skill.contentFingerprint,
                confirmedAtMilliseconds: 301
            ),
            LocalSkillOriginRecord(
                skillID: skillID,
                scope: .custom(
                    pathID: UUID(uuidString: "22334455-6677-8899-aabb-ccddeeff0011")!,
                    adapterCode: "claude",
                    pathVariant: ".claude/skills"
                ),
                rawLocator: "Sample",
                normalizedLocator: "Sample",
                collisionKey: SkillContentPath.collisionKey(for: "Sample"),
                fingerprint: skill.contentFingerprint,
                confirmedAtMilliseconds: 302
            ),
        ]
    } else {
        []
    }
    return try SSOTSkillWritePayload(
        skill: skill,
        source: source,
        providerAliases: aliases,
        localOrigins: localOrigins
    )
}
