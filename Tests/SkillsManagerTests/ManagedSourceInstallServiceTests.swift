import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed source install service")
struct ManagedSourceInstallServiceTests {
    @Test("new source install persists source and skills.sh alias")
    func createsSourceAndAlias() async throws {
        try await withImportCandidate { candidate in
            let state = try SourceInstallReadbackState(revision: "abc123")
            let probe = ManagedLocalImportProbe()
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )
            let input = try sourceInput(state: state, revision: "abc123")

            let preview = try await service.prepareSourceBacked(
                candidate: candidate,
                sourceInput: input,
                scope: .global
            )
            let result = try await service.execute(preview.token)
            let payload = try #require(await probe.createdPayload)

            #expect(result.status == .distributed)
            #expect(payload.skill.skillID == preview.skillID)
            #expect(payload.source?.repositoryURL == input.repositoryURL)
            #expect(payload.source?.subpath == input.subpath)
            #expect(payload.source?.revision == input.revision)
            #expect(payload.providerAliases.map(\.identity) == [input.alias])
        }
    }

    @Test("same source update preserves stable identity and domain metadata")
    func updatePreservesIdentityAndMetadata() async throws {
        try await withImportCandidate { candidate in
            let oldAlias = try sourceAlias("example/repository:old")
            let newAlias = try sourceAlias("example/repository:new")
            let existing = try sourcePayload(
                candidate: candidate,
                revision: "old",
                aliases: [oldAlias],
                includePreservedMetadata: true
            )
            let state = try SourceInstallReadbackState(
                revision: "new",
                domain: StoredSkillDomainSnapshot(payload: existing, revision: 1)
            )
            let probe = ManagedLocalImportProbe(existingPayload: existing)
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )
            let input = try sourceInput(
                state: state,
                revision: "new",
                alias: newAlias
            )

            let preview = try await service.prepareSourceBacked(
                candidate: candidate,
                sourceInput: input,
                scope: .global
            )
            let result = try await service.execute(preview.token)
            let updated = try #require(await probe.createdPayload)

            #expect(preview.disposition == .updateRequired)
            #expect(result.status == .updated)
            #expect(updated.skill.skillID == existing.skill.skillID)
            #expect(updated.source?.sourceID == existing.source?.sourceID)
            #expect(updated.source?.revision == input.revision)
            #expect(Set(updated.providerAliases.map(\.identity)) == [oldAlias, newAlias])
            #expect(updated.providerProvenance == existing.providerProvenance)
            #expect(updated.restoredFromSkillID == existing.restoredFromSkillID)
            #expect(updated.forkLineage == existing.forkLineage)
            #expect(await probe.createCount == 0)
            #expect(await probe.replaceCount == 1)
        }
    }

    @Test("local origins reject source update before any write")
    func localOriginsRejectUpdate() async throws {
        try await withImportCandidate { candidate in
            let existing = try sourcePayload(
                candidate: candidate,
                revision: "old",
                aliases: [sourceAlias("example/repository:old")],
                includeLocalOrigin: true
            )
            let state = try SourceInstallReadbackState(
                revision: "new",
                domain: StoredSkillDomainSnapshot(payload: existing, revision: 1)
            )
            let probe = ManagedLocalImportProbe(existingPayload: existing)
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )

            await #expect(
                throws: ManagedLocalImportProblem.sourceUpdateUnsupportedLocalOrigins
            ) {
                _ = try await service.prepareSourceBacked(
                    candidate: candidate,
                    sourceInput: sourceInput(
                        state: state,
                        revision: "new",
                        alias: sourceAlias("example/repository:new")
                    ),
                    scope: .global
                )
            }
            #expect(await probe.createCount == 0)
            #expect(await probe.replaceCount == 0)
        }
    }

    @Test("alias limit rejects source update before any write")
    func aliasLimitRejectsUpdate() async throws {
        try await withImportCandidate { candidate in
            let aliases = try (0..<SSOTSkillWritePayload.maximumProviderAliasCount).map {
                try sourceAlias("example/repository:\($0)")
            }
            let existing = try sourcePayload(
                candidate: candidate,
                revision: "old",
                aliases: aliases
            )
            let state = try SourceInstallReadbackState(
                revision: "new",
                domain: StoredSkillDomainSnapshot(payload: existing, revision: 1)
            )
            let probe = ManagedLocalImportProbe(existingPayload: existing)
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )

            await #expect(throws: ManagedLocalImportProblem.aliasLimitReached) {
                _ = try await service.prepareSourceBacked(
                    candidate: candidate,
                    sourceInput: sourceInput(
                        state: state,
                        revision: "new",
                        alias: sourceAlias("example/repository:new")
                    ),
                    scope: .global
                )
            }
            #expect(await probe.createCount == 0)
            #expect(await probe.replaceCount == 0)
        }
    }

    @Test(
        "head, source, and alias races expire before any write",
        arguments: SourceInstallRace.allCases
    )
    func admissionRace(race: SourceInstallRace) async throws {
        try await withImportCandidate { candidate in
            let state = try SourceInstallReadbackState(revision: "abc123")
            let probe = ManagedLocalImportProbe()
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )
            let input = try sourceInput(state: state, revision: "abc123")
            let preview = try await service.prepareSourceBacked(
                candidate: candidate,
                sourceInput: input,
                scope: .global
            )

            switch race {
            case .head:
                await state.setRevision(try SourceRevision("different"))
            case .source:
                let conflicting = try sourcePayload(
                    candidate: candidate,
                    revision: "different",
                    aliases: [try sourceAlias("different")]
                )
                await state.setDomain(
                    StoredSkillDomainSnapshot(payload: conflicting, revision: 1)
                )
            case .alias:
                await state.setAliasOwner(ProviderAliasSourceOwner(
                    sourceID: SourceID(),
                    skillID: SkillID()
                ))
            }

            await #expect(throws: ManagedLocalImportProblem.previewExpired) {
                _ = try await service.execute(preview.token)
            }
            #expect(await probe.createCount == 0)
            #expect(await probe.replaceCount == 0)
        }
    }

    @Test("blocked source install remains managed but undistributed")
    func blockedCreate() async throws {
        try await withImportCandidate { candidate in
            let state = try SourceInstallReadbackState(revision: "abc123")
            let probe = ManagedLocalImportProbe(planStatuses: [.blocked])
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )
            let preview = try await service.prepareSourceBacked(
                candidate: candidate,
                sourceInput: sourceInput(state: state, revision: "abc123"),
                scope: .global
            )

            let result = try await service.execute(preview.token)

            #expect(result.status == .managedUndistributed)
            #expect(await probe.createCount == 1)
            #expect(await probe.applyCount == 0)
        }
    }

    @Test("post-commit distribution uncertainty remains managed and indeterminate")
    func distributionIndeterminateAfterCreate() async throws {
        try await withImportCandidate { candidate in
            let state = try SourceInstallReadbackState(revision: "abc123")
            let probe = ManagedLocalImportProbe(
                applyThrows: true,
                reconcileStatus: .needsRepair
            )
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )
            let preview = try await service.prepareSourceBacked(
                candidate: candidate,
                sourceInput: sourceInput(state: state, revision: "abc123"),
                scope: .global
            )

            let result = try await service.execute(preview.token)

            #expect(result.status == .managedDistributionIndeterminate)
            #expect(await probe.createCount == 1)
            #expect(await probe.applyCount == 1)
        }
    }

    @Test("provider provenance alone does not merge a source-backed install")
    func provenanceOnlyDoesNotMerge() async throws {
        try await withImportCandidate { candidate in
            let existing = try sourcePayload(
                candidate: candidate,
                revision: "old",
                aliases: [sourceAlias("example/other:old")],
                includePreservedMetadata: true
            )
            let state = try SourceInstallReadbackState(revision: "abc123")
            let probe = ManagedLocalImportProbe(
                planStatuses: [.blocked],
                existingPayload: existing,
                existingProvenance: existing.providerProvenance.first
            )
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )

            let preview = try await service.prepareSourceBacked(
                candidate: candidate,
                sourceInput: sourceInput(state: state, revision: "abc123"),
                scope: .global
            )
            let result = try await service.execute(preview.token)

            #expect(preview.skillID != existing.skill.skillID)
            #expect(result.status == .managedUndistributed)
            #expect(await probe.createCount == 1)
            #expect(await probe.replaceCount == 0)
        }
    }

    @Test("distribution plan drift expires before any source write")
    func planDriftExpires() async throws {
        try await withImportCandidate { candidate in
            let state = try SourceInstallReadbackState(revision: "abc123")
            let probe = ManagedLocalImportProbe(planStatuses: [.executable, .noOp])
            let service = ManagedInstallService(
                dependencies: sourceDependencies(probe, state: state)
            )
            let preview = try await service.prepareSourceBacked(
                candidate: candidate,
                sourceInput: sourceInput(state: state, revision: "abc123"),
                scope: .global
            )

            await #expect(throws: ManagedLocalImportProblem.previewExpired) {
                _ = try await service.execute(preview.token)
            }
            #expect(await probe.createCount == 0)
            #expect(await probe.replaceCount == 0)
        }
    }
}

enum SourceInstallRace: CaseIterable, Sendable {
    case head
    case source
    case alias
}

private actor SourceInstallReadbackState {
    private var revision: SourceRevision
    private var domain: StoredSkillDomainSnapshot?
    private var aliasOwner: ProviderAliasSourceOwner?

    init(
        revision: String,
        domain: StoredSkillDomainSnapshot? = nil,
        aliasOwner: ProviderAliasSourceOwner? = nil
    ) throws {
        self.revision = try SourceRevision(revision)
        self.domain = domain
        self.aliasOwner = aliasOwner
    }

    func currentRevision() -> SourceRevision { revision }
    func sourceDomain() -> StoredSkillDomainSnapshot? { domain }
    func currentAliasOwner() -> ProviderAliasSourceOwner? { aliasOwner }
    func setRevision(_ value: SourceRevision) { revision = value }
    func setDomain(_ value: StoredSkillDomainSnapshot) { domain = value }
    func setAliasOwner(_ value: ProviderAliasSourceOwner) { aliasOwner = value }
}

private func sourceDependencies(
    _ probe: ManagedLocalImportProbe,
    state: SourceInstallReadbackState
) -> ManagedInstallDependencies {
    let base = probe.dependencies()
    return ManagedInstallDependencies(
        plan: base.plan,
        create: base.create,
        operationReadback: base.operationReadback,
        domainReadback: base.domainReadback,
        provenanceReadback: base.provenanceReadback,
        sourceReadback: { _, _ in await state.sourceDomain() },
        aliasOwnerReadback: { _ in await state.currentAliasOwner() },
        updateBaseline: base.updateBaseline,
        replaceWithBackup: base.replaceWithBackup,
        createSourceBacked: base.createSourceBacked,
        replaceSourceBackedWithBackup: base.replaceSourceBackedWithBackup,
        apply: base.apply,
        reconcile: base.reconcile,
        nowMilliseconds: base.nowMilliseconds
    )
}

private func sourceInput(
    state: SourceInstallReadbackState,
    revision: String,
    alias: ProviderAliasIdentity? = nil
) throws -> ManagedSourceInstallInput {
    ManagedSourceInstallInput(
        displayName: "Source Demo",
        distributionSlug: try DefaultDistributionSlug(validating: "source-demo"),
        repositoryURL: try NormalizedRepositoryURL(
            "https://github.com/example/repository"
        ),
        subpath: try RepositorySubpath("skills/demo"),
        revision: try SourceRevision(revision),
        downloadURL: try PublicDownloadURL(
            "https://codeload.github.com/example/repository/legacy.zip/\(revision)"
        ),
        alias: try alias ?? sourceAlias("example/repository:demo"),
        refreshHead: { await state.currentRevision() }
    )
}

private func sourceAlias(_ identifier: String) throws -> ProviderAliasIdentity {
    try ProviderAliasIdentity(provider: "skills.sh", identifier: identifier)
}

private func sourcePayload(
    candidate: SkillImportWorker.ImportCandidatePayload,
    revision: String,
    aliases: [ProviderAliasIdentity],
    includeLocalOrigin: Bool = false,
    includePreservedMetadata: Bool = false
) throws -> SSOTSkillWritePayload {
    let skillID = SkillID()
    let sourceID = SourceID()
    let fingerprint = try SkillContentFingerprint(
        currentDigest: candidate.snapshot.fingerprintDigest
    )
    let skill = try ManagedSkillRecord(
        skillID: skillID,
        displayName: SkillDisplayName("Existing Source"),
        defaultDistributionSlug: DefaultDistributionSlug(validating: "existing-source"),
        contentFingerprint: fingerprint,
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
    let provenance: [ProviderProvenanceRecord] = includePreservedMetadata ? [
        try ProviderProvenanceRecord(
            skillID: skillID,
            identity: ProviderAliasIdentity(
                provider: "clawdhub",
                identifier: "existing-source"
            ),
            identifierKey: "existing-source",
            version: try SourceVersion("1.0.0")
        ),
    ] : []
    let localOrigins: [LocalSkillOriginRecord] = includeLocalOrigin ? [
        try LocalSkillOriginRecord(
            skillID: skillID,
            scope: .global,
            rawLocator: "existing-source",
            normalizedLocator: "existing-source",
            collisionKey: "existing-source",
            fingerprint: fingerprint,
            confirmedAtMilliseconds: 1
        ),
    ] : []
    let restoredFrom: SkillID?
    let lineage: SkillForkLineageRecord?
    if includePreservedMetadata {
        restoredFrom = SkillID()
        lineage = try SkillForkLineageRecord(
            forkSkillID: skillID,
            parentSkillID: SkillID(),
            forkedFromFingerprint: fingerprint,
            createdAtMilliseconds: 1
        )
    } else {
        restoredFrom = nil
        lineage = nil
    }
    return try SSOTSkillWritePayload(
        skill: skill,
        source: SkillSourceRecord(
            sourceID: sourceID,
            skillID: skillID,
            repositoryURL: try NormalizedRepositoryURL(
                "https://github.com/example/repository"
            ),
            subpath: try RepositorySubpath("skills/demo"),
            revision: try SourceRevision(revision),
            downloadURL: try PublicDownloadURL(
                "https://codeload.github.com/example/repository/legacy.zip/\(revision)"
            )
        ),
        providerAliases: aliases.map {
            ProviderAliasRecord(sourceID: sourceID, identity: $0)
        },
        providerProvenance: provenance,
        localOrigins: localOrigins,
        restoredFromSkillID: restoredFrom,
        forkLineage: lineage
    )
}
