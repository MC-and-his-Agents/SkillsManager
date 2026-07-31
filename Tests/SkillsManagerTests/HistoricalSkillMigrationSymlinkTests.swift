import Darwin
import Testing

@testable import SkillsManager

extension HistoricalSkillMigrationTests {
    @Test("external Skill links are never migrated by the historical replacement flow")
    func externalSkillLinkCannotMigrate() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# External")
        let prepared = try await fixture.prepare()
        let observation = linkedObservation(prepared.observation)
        let original = prepared.audit.manifest
        let manifest = SkillConsistencyAuditManifest(
            schema: original.schema,
            coverage: original.coverage,
            health: original.health,
            root: original.root,
            managedSkills: original.managedSkills,
            distributions: original.distributions,
            discovery: SkillConsistencyAuditDiscovery(
                roots: original.discovery.roots,
                rootDiagnostics: original.discovery.rootDiagnostics,
                observations: [
                    try SkillConsistencyAuditWire.discoveryObservation(observation),
                ]
            )
        )
        let audit = SkillConsistencyAuditPrepared(
            manifest: manifest,
            canonicalBytes: try SkillConsistencyAuditManifestCodec.encode(manifest),
            discoveryObservations: [observation]
        )

        await #expect(throws: HistoricalSkillMigrationError.unsupportedCandidate) {
            _ = try await fixture.service().prepare(
                audit: audit,
                observation: observation,
                importAction: .importNew
            )
        }

        #expect(try fixture.workspace.integer("SELECT count(*) FROM skills") == 0)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 0)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 0)
        #expect(try !fixture.isSourceSymlink())
    }
}

private func linkedObservation(
    _ observation: SkillDiscoveryObservation
) -> SkillDiscoveryObservation {
    SkillDiscoveryObservation(
        roots: observation.roots,
        rootIdentity: observation.rootIdentity,
        rawRelativeLocator: observation.rawRelativeLocator,
        relativeLocator: observation.relativeLocator,
        relativeLocatorKey: observation.relativeLocatorKey,
        candidateIdentity: observation.candidateIdentity,
        symbolicLinkIdentity: ManagedItemIdentity(
            persistedComponents: .init(
                device: 1,
                inode: 9,
                fileType: UInt32(S_IFLNK),
                generation: 0
            )
        ),
        fingerprint: observation.fingerprint,
        providerAliases: observation.providerAliases,
        status: observation.status,
        reason: observation.reason,
        matchedSkillID: observation.matchedSkillID,
        matchedSourceKey: observation.matchedSourceKey
    )
}
