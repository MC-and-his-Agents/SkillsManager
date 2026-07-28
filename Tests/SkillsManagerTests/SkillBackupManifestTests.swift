import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill backup manifest")
struct SkillBackupManifestTests {
    @Test("encodes the V1 golden bytes and rebuilds the payload")
    func goldenBytesAndRoundTrip() throws {
        let manifest = try makeManifest()
        let encoded = try manifest.encoded()
        let fingerprint = String(repeating: "ab", count: 32)
        let expected = """
        {"aliases":[],"backup_id":"aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb","content":{"content_fingerprint":"\(fingerprint)","file_count":2,"fingerprint_algorithm_version":1,"total_byte_count":42},"created_at_ms":12,"database_revision":3,"distribution_selection":{"bindings":[],"explicitly_configured":true},"local_origins":[],"original_skill_id":"00112233-4455-4677-8899-aabbccddeeff","schema_version":1,"skill":{"content_fingerprint":"\(fingerprint)","created_at_ms":10,"default_distribution_slug":"demo","display_name":"Demo","fingerprint_algorithm_version":1,"skill_id":"00112233-4455-4677-8899-aabbccddeeff","status":"managed","updated_at_ms":11},"source":null}
        """

        #expect(encoded == Data(expected.utf8))
        let decoded = try SkillBackupManifestV1.decode(encoded)
        #expect(try decoded.encoded() == encoded)
        #expect(decoded.payload.skill.skillID == manifest.payload.skill.skillID)
        #expect(decoded.payload.source == nil)
        #expect(decoded.payload.providerAliases.isEmpty)
        #expect(decoded.payload.localOrigins.isEmpty)
        #expect(decoded.payload.restoredFromSkillID == nil)
        #expect(decoded.distributionSelection.isExplicitlyConfigured)
        #expect(decoded.distributionSelection.bindingIntents.isEmpty)
        #expect(decoded.statistics == .init(fileCount: 2, totalByteCount: 42))
    }

    @Test("round-trips complete domain and distribution state in canonical order")
    func completeRoundTrip() throws {
        let manifest = try makeManifest(includeDomainState: true)
        let decoded = try SkillBackupManifestV1.decode(manifest.encoded())

        #expect(decoded.payload.source == manifest.payload.source)
        #expect(decoded.payload.providerAliases == manifest.payload.providerAliases)
        #expect(decoded.payload.providerProvenance == manifest.payload.providerProvenance)
        #expect(decoded.payload.localOrigins == manifest.payload.localOrigins)
        #expect(decoded.payload.restoredFromSkillID == manifest.payload.restoredFromSkillID)
        #expect(
            decoded.distributionSelection.bindingIntents
                == manifest.distributionSelection.bindingIntents
        )
        #expect(
            decoded.payload.providerAliases.map(\.identity.provider)
                == ["clawdhub", "skills.sh"]
        )
        #expect(
            decoded.distributionSelection.bindingIntents.map(\.scope.targetScopeKey)
                == ["agent:codex", "agent:copilot"]
        )
    }

    @Test("round-trips Fork lineage without changing legacy golden bytes")
    func forkLineageRoundTrip() throws {
        let ordinary = try makeManifest()
        let lineage = try SkillForkLineageRecord(
            forkSkillID: ordinary.originalSkillID,
            parentSkillID: SkillID(
                UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!
            ),
            forkedFromFingerprint: SkillContentFingerprint(
                currentDigest: Data(repeating: 0xcd, count: 32)
            ),
            createdAtMilliseconds: 9,
            originType: .localFork
        )
        let payload = try SSOTSkillWritePayload(
            skill: ordinary.payload.skill,
            forkLineage: lineage
        )
        let manifest = try SkillBackupManifestV1(
            backupID: ordinary.backupID,
            payload: payload,
            databaseRevision: ordinary.databaseRevision,
            distributionSelection: ordinary.distributionSelection,
            statistics: ordinary.statistics,
            createdAtMilliseconds: ordinary.createdAtMilliseconds
        )
        let encoded = try manifest.encoded()
        let decoded = try SkillBackupManifestV1.decode(encoded)

        #expect(decoded.payload.forkLineage == lineage)
        #expect(try decoded.encoded() == encoded)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"fork_lineage\""))
    }

    @Test("round-trips complete historical migration metadata")
    func historicalMigrationMetadataRoundTrip() throws {
        let ordinary = try makeManifest()
        let workspace = try WriterWorkspace()
        let candidate = workspace.workspace.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        let metadata = try SkillBackupMigrationMetadata(
            operationID: SSOTOperationID(
                UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
            ),
            sourceScope: .global,
            rawLocator: "demo",
            normalizedLocator: "demo",
            rootIdentity: workspace.verifiedRoot.identity,
            candidateIdentity: try ManagedRootReference.capture(at: candidate)
                .verifiedRoot().identity,
            fingerprint: ordinary.contentFingerprint,
            createdAtMilliseconds: ordinary.createdAtMilliseconds
        )
        let manifest = try SkillBackupManifestV1(
            backupID: ordinary.backupID,
            payload: ordinary.payload,
            databaseRevision: ordinary.databaseRevision,
            distributionSelection: ordinary.distributionSelection,
            statistics: ordinary.statistics,
            createdAtMilliseconds: ordinary.createdAtMilliseconds,
            migrationMetadata: metadata
        )
        let encoded = try manifest.encoded()
        let decoded = try SkillBackupManifestV1.decode(encoded)

        #expect(decoded.migrationMetadata == metadata)
        #expect(try decoded.encoded() == encoded)
        #expect(String(decoding: encoded, as: UTF8.self).contains(
            "\"reason\":\"historical_skill_migration\""
        ))
    }

    @Test("rejects incomplete or tampered historical migration metadata")
    func rejectsInvalidHistoricalMigrationMetadata() throws {
        let ordinary = try makeManifest()
        let workspace = try WriterWorkspace()
        let candidate = workspace.workspace.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        let metadata = try SkillBackupMigrationMetadata(
            operationID: SSOTOperationID(),
            sourceScope: .global,
            rawLocator: "demo",
            normalizedLocator: "demo",
            rootIdentity: workspace.verifiedRoot.identity,
            candidateIdentity: try ManagedRootReference.capture(at: candidate)
                .verifiedRoot().identity,
            fingerprint: ordinary.contentFingerprint,
            createdAtMilliseconds: ordinary.createdAtMilliseconds
        )
        let encoded = try SkillBackupManifestV1(
            backupID: ordinary.backupID,
            payload: ordinary.payload,
            databaseRevision: ordinary.databaseRevision,
            distributionSelection: ordinary.distributionSelection,
            statistics: ordinary.statistics,
            createdAtMilliseconds: ordinary.createdAtMilliseconds,
            migrationMetadata: metadata
        ).encoded()
        let raw = String(decoding: encoded, as: UTF8.self)
        let incomplete = raw.replacingOccurrences(
            of: "\"reason\":\"historical_skill_migration\",",
            with: ""
        )
        let tampered = raw.replacingOccurrences(
            of: "historical_skill_migration",
            with: "unexpected"
        )

        #expect(throws: SkillBackupManifestError.self) {
            try SkillBackupManifestV1.decode(Data(incomplete.utf8))
        }
        #expect(throws: SkillBackupManifestError.self) {
            try SkillBackupManifestV1.decode(Data(tampered.utf8))
        }
    }

    @Test("rejects missing null fields and non-lowercase identities")
    func rejectsNonCanonicalIdentityForms() throws {
        let encoded = try makeManifest().encoded()
        let raw = String(decoding: encoded, as: UTF8.self)
        let missingSource = raw.replacingOccurrences(of: ",\"source\":null", with: "")
        let uppercaseUUID = raw.replacingOccurrences(
            of: "00112233-4455-4677-8899-aabbccddeeff",
            with: "00112233-4455-4677-8899-AABBCCDDEEFF"
        )
        let uppercaseHex = raw.replacingOccurrences(
            of: String(repeating: "ab", count: 32),
            with: String(repeating: "AB", count: 32)
        )

        #expect(throws: SkillBackupManifestError.self) {
            try SkillBackupManifestV1.decode(Data(missingSource.utf8))
        }
        #expect(throws: SkillBackupManifestError.self) {
            try SkillBackupManifestV1.decode(Data(uppercaseUUID.utf8))
        }
        #expect(throws: SkillBackupManifestError.self) {
            try SkillBackupManifestV1.decode(Data(uppercaseHex.utf8))
        }
    }

    @Test("rejects duplicate binding target keys")
    func rejectsDuplicateBindingTargets() throws {
        let skillID = fixedSkillID
        let slug = try DefaultDistributionSlug(validating: "demo")
        let duplicate = DistributionBindingIntent(
            skillID: skillID,
            scope: .agent(.codex),
            distributionSlug: slug
        )

        #expect(throws: SkillBackupManifestError.invalidManifest) {
            try SkillBackupDistributionSelection(
                isExplicitlyConfigured: true,
                bindingIntents: [duplicate, duplicate]
            )
        }
    }
}

private let fixedSkillID = SkillID(
    UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!
)

private func makeManifest(
    includeDomainState: Bool = false
) throws -> SkillBackupManifestV1 {
    let fingerprint = try SkillContentFingerprint(
        algorithmVersion: 1,
        digest: Data(repeating: 0xab, count: 32)
    )
    let skill = try ManagedSkillRecord(
        skillID: fixedSkillID,
        displayName: SkillDisplayName("Demo"),
        defaultDistributionSlug: DefaultDistributionSlug(validating: "demo"),
        contentFingerprint: fingerprint,
        createdAtMilliseconds: 10,
        updatedAtMilliseconds: 11
    )
    let source: SkillSourceRecord?
    if includeDomainState {
        source = try makeSource(skillID: fixedSkillID)
    } else {
        source = nil
    }
    let aliases = try source.map {
        [
            ProviderAliasRecord(
                sourceID: $0.sourceID,
                identity: try ProviderAliasIdentity(provider: "skills.sh", identifier: "demo")
            ),
            ProviderAliasRecord(
                sourceID: $0.sourceID,
                identity: try ProviderAliasIdentity(provider: "clawdhub", identifier: "demo")
            ),
        ]
    } ?? []
    let origins: [LocalSkillOriginRecord]
    if includeDomainState {
        origins = [
            try LocalSkillOriginRecord(
                skillID: fixedSkillID,
                scope: .agent(adapterCode: "codex", pathVariant: ".codex/skills"),
                rawLocator: "demo",
                normalizedLocator: "demo",
                collisionKey: SkillContentPath.collisionKey(for: "demo"),
                fingerprint: fingerprint,
                confirmedAtMilliseconds: 9
            ),
        ]
    } else {
        origins = []
    }
    let slug = try DefaultDistributionSlug(validating: "demo")
    let provenance = includeDomainState ? [
        try ProviderProvenanceRecord(
            skillID: fixedSkillID,
            identity: ProviderAliasIdentity(
                provider: "clawdhub",
                identifier: slug.value
            ),
            identifierKey: slug.collisionKey,
            version: try SourceVersion("1.0.0")
        ),
    ] : []
    let bindings = includeDomainState ? [
        DistributionBindingIntent(
            skillID: fixedSkillID,
            scope: .agent(.copilot),
            distributionSlug: slug
        ),
        DistributionBindingIntent(
            skillID: fixedSkillID,
            scope: .agent(.codex),
            distributionSlug: slug
        ),
    ] : []
    let payload = try SSOTSkillWritePayload(
        skill: skill,
        source: source,
        providerAliases: aliases,
        providerProvenance: provenance,
        localOrigins: origins,
        restoredFromSkillID: includeDomainState
            ? SkillID(UUID(uuidString: "9999aaaa-bbbb-4ccc-8ddd-eeeeffff0000")!)
            : nil
    )
    return try SkillBackupManifestV1(
        backupID: SkillBackupID(
            UUID(uuidString: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")!
        ),
        payload: payload,
        databaseRevision: 3,
        distributionSelection: SkillBackupDistributionSelection(
            isExplicitlyConfigured: true,
            bindingIntents: bindings
        ),
        statistics: .init(fileCount: 2, totalByteCount: 42),
        createdAtMilliseconds: 12
    )
}

private func makeSource(skillID: SkillID) throws -> SkillSourceRecord {
    SkillSourceRecord(
        sourceID: SourceID(
            UUID(uuidString: "11112222-3333-4444-8555-666677778888")!
        ),
        skillID: skillID,
        repositoryURL: try NormalizedRepositoryURL("https://github.com/example/repo"),
        subpath: try RepositorySubpath("skills/demo"),
        revision: try SourceRevision("deadbeef"),
        version: try SourceVersion("1.0.0"),
        downloadURL: try PublicDownloadURL(
            "https://github.com/example/repo/archive/deadbeef.zip"
        )
    )
}
