import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill discovery classification")
struct SkillDiscoveryClassifierTests {
    @Test("unique fingerprint is claimable")
    func uniqueFingerprintIsClaimable() throws {
        let skill = managedSkill(id: 1, fingerprintByte: 7)
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 7)],
            catalog: SkillDiscoveryCatalog(managedSkills: [skill])
        ).first)

        #expect(observation.status == .claimable)
        #expect(observation.matchedSkillID == skill.skillID)
        #expect(observation.reason == nil)
    }

    @Test("same-scope collision siblings conflict even when content matches")
    func slugConflictWinsOverFingerprintMatch() {
        let skill = managedSkill(id: 1, fingerprintByte: 7)
        let observations = classify([
            candidate(name: "Demo", fingerprintByte: 7),
            candidate(name: "demo", fingerprintByte: 7),
        ], catalog: SkillDiscoveryCatalog(managedSkills: [skill]))

        #expect(observations.count == 2)
        #expect(observations.allSatisfy { $0.status == .conflict })
        #expect(observations.allSatisfy { $0.reason == .scopeSlugConflict })
    }

    @Test("consistent aliases across scopes remain one managed observation")
    func consistentAliasesAreManaged() throws {
        let skill = managedSkill(id: 1, fingerprintByte: 7)
        let agent = SkillDiscoveryScope.agent(
            adapterCode: "codex",
            pathVariant: ".codex/skills"
        )
        let global = SkillDiscoveryScope.global
        let associations = [agent, global].map {
            SkillDiscoveryLocalAssociation(
                scope: $0,
                relativeLocatorKey: "demo",
                skillID: skill.skillID,
                fingerprint: skill.fingerprint
            )
        }
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 7, scopes: [agent, global])],
            catalog: SkillDiscoveryCatalog(
                managedSkills: [skill],
                localAssociations: associations
            )
        ).first)

        #expect(observation.status == .managed)
        #expect(observation.matchedSkillID == skill.skillID)
    }

    @Test("a partially associated alias set remains claimable")
    func partiallyAssociatedAliasesAreClaimable() throws {
        let skill = managedSkill(id: 1, fingerprintByte: 7)
        let agent = SkillDiscoveryScope.agent(
            adapterCode: "codex",
            pathVariant: ".codex/skills"
        )
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 7, scopes: [agent, .global])],
            catalog: SkillDiscoveryCatalog(
                managedSkills: [skill],
                localAssociations: [
                    SkillDiscoveryLocalAssociation(
                        scope: .global,
                        relativeLocatorKey: "demo",
                        skillID: skill.skillID,
                        fingerprint: skill.fingerprint
                    ),
                ]
            )
        ).first)

        #expect(observation.status == .claimable)
        #expect(observation.matchedSkillID == skill.skillID)
    }

    @Test("aliases associated with different skills are ambiguous")
    func aliasesWithDifferentSkillsConflict() throws {
        let first = managedSkill(id: 1, fingerprintByte: 7)
        let second = managedSkill(id: 2, fingerprintByte: 7)
        let agent = SkillDiscoveryScope.agent(
            adapterCode: "codex",
            pathVariant: ".codex/skills"
        )
        let global = SkillDiscoveryScope.global
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 7, scopes: [agent, global])],
            catalog: SkillDiscoveryCatalog(
                managedSkills: [first, second],
                localAssociations: [
                    SkillDiscoveryLocalAssociation(
                        scope: agent,
                        relativeLocatorKey: "demo",
                        skillID: first.skillID,
                        fingerprint: first.fingerprint
                    ),
                    SkillDiscoveryLocalAssociation(
                        scope: global,
                        relativeLocatorKey: "demo",
                        skillID: second.skillID,
                        fingerprint: second.fingerprint
                    ),
                ]
            )
        ).first)

        #expect(observation.status == .conflict)
        #expect(observation.reason == .ambiguousLocalAssociation)
    }

    @Test("provider and fingerprint evidence for different skills conflict")
    func sourceAndFingerprintConflict() throws {
        let alias = try ProviderAliasIdentity(provider: "clawdhub", identifier: "demo")
        let sourceSkill = managedSkill(id: 1, fingerprintByte: 1, aliases: [alias])
        let contentSkill = managedSkill(id: 2, fingerprintByte: 2)
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 2, aliases: [alias])],
            catalog: SkillDiscoveryCatalog(managedSkills: [sourceSkill, contentSkill])
        ).first)

        #expect(observation.status == .conflict)
        #expect(observation.reason == .evidenceConflict)
    }

    @Test("unique source evidence with different content is a conflict")
    func uniqueSourceWithDifferentContentConflicts() throws {
        let alias = try ProviderAliasIdentity(provider: "clawdhub", identifier: "demo")
        let sourceSkill = managedSkill(id: 1, fingerprintByte: 1, aliases: [alias])
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 2, aliases: [alias])],
            catalog: SkillDiscoveryCatalog(managedSkills: [sourceSkill])
        ).first)

        #expect(observation.status == .conflict)
        #expect(observation.reason == .evidenceConflict)
        #expect(observation.matchedSkillID == nil)
    }

    @Test("provider aliases without a persisted Source are not source evidence")
    func orphanProviderAliasIsIgnored() throws {
        let alias = try ProviderAliasIdentity(provider: "clawdhub", identifier: "demo")
        let managed = SkillDiscoveryManagedSkill(
            skillID: SkillID(),
            fingerprint: fingerprint(1),
            sourceKey: nil,
            providerAliases: [alias]
        )
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 2, aliases: [alias])],
            catalog: SkillDiscoveryCatalog(managedSkills: [managed])
        ).first)

        #expect(observation.status == .unmanaged)
        #expect(observation.matchedSkillID == nil)
        #expect(observation.matchedSourceKey == nil)
    }

    @Test("ambiguous fingerprints are conflicts")
    func ambiguousFingerprintConflicts() throws {
        let first = managedSkill(id: 1, fingerprintByte: 7)
        let second = managedSkill(id: 2, fingerprintByte: 7)
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 7)],
            catalog: SkillDiscoveryCatalog(managedSkills: [first, second])
        ).first)

        #expect(observation.status == .conflict)
        #expect(observation.reason == .ambiguousFingerprint)
    }

    @Test("local association fingerprint drift is a conflict")
    func localAssociationDriftConflicts() throws {
        let skill = managedSkill(id: 1, fingerprintByte: 7)
        let association = SkillDiscoveryLocalAssociation(
            scope: .global,
            relativeLocatorKey: "demo",
            skillID: skill.skillID,
            fingerprint: fingerprint(6)
        )
        let observation = try #require(classify(
            [candidate(name: "demo", fingerprintByte: 7)],
            catalog: SkillDiscoveryCatalog(
                managedSkills: [skill],
                localAssociations: [association]
            )
        ).first)

        #expect(observation.status == .conflict)
        #expect(observation.reason == .localAssociationDrift)
    }

    @Test("terminal observations do not require a fingerprint")
    func terminalObservationNeedsNoFingerprint() throws {
        let failed = SkillDiscoveryCandidate(
            roots: [root(scope: .global)],
            rootIdentity: ManagedItemIdentity(stat()),
            rawRelativeLocator: "demo",
            relativeLocator: "demo",
            relativeLocatorKey: "demo",
            candidateIdentity: nil,
            fingerprint: nil,
            providerAliases: [],
            terminalStatus: .permissionDenied,
            terminalReason: .candidatePermissionDenied
        )
        let observation = try #require(classify([failed], catalog: .empty).first)

        #expect(observation.status == .permissionDenied)
        #expect(observation.reason == .candidatePermissionDenied)
        #expect(observation.fingerprint == nil)
    }

    private func classify(
        _ candidates: [SkillDiscoveryCandidate],
        catalog: SkillDiscoveryCatalog
    ) -> [SkillDiscoveryObservation] {
        SkillDiscoveryClassifier().classify(candidates, catalog: catalog)
    }

    private func candidate(
        name: String,
        fingerprintByte: UInt8,
        scopes: [SkillDiscoveryScope] = [.global],
        aliases: Set<ProviderAliasIdentity> = []
    ) -> SkillDiscoveryCandidate {
        SkillDiscoveryCandidate(
            roots: scopes.map(root(scope:)),
            rootIdentity: ManagedItemIdentity(stat()),
            rawRelativeLocator: name,
            relativeLocator: name,
            relativeLocatorKey: SkillContentPath.collisionKey(for: name),
            candidateIdentity: nil,
            fingerprint: fingerprint(fingerprintByte),
            providerAliases: aliases,
            terminalStatus: nil,
            terminalReason: nil
        )
    }

    private func root(scope: SkillDiscoveryScope) -> SkillDiscoveryRoot {
        SkillDiscoveryRoot(
            scope: scope,
            url: URL(fileURLWithPath: "/discovery/\(scope.sortKey.hashValue)", isDirectory: true)
        )
    }

    private func managedSkill(
        id: UInt8,
        fingerprintByte: UInt8,
        aliases: Set<ProviderAliasIdentity> = []
    ) -> SkillDiscoveryManagedSkill {
        SkillDiscoveryManagedSkill(
            skillID: SkillID(UUID(uuid: (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, id
            ))),
            fingerprint: fingerprint(fingerprintByte),
            sourceKey: aliases.isEmpty ? nil : SkillDiscoverySourceKey(
                repositoryURL: "https://github.com/example/demo",
                subpath: ""
            ),
            providerAliases: aliases
        )
    }

    private func fingerprint(_ byte: UInt8) -> SkillContentFingerprint {
        try! SkillContentFingerprint(currentDigest: Data(repeating: byte, count: 32))
    }
}
