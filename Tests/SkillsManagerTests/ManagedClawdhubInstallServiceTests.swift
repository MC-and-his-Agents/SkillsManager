import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed Clawdhub install")
struct ManagedClawdhubInstallServiceTests {
    @Test("new Clawdhub install persists provider provenance and uses the remote slug")
    func createsManagedSkill() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe()
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let remote = remoteSkill(slug: "remote-demo", version: "1.2.3")

            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remote,
                scope: .global
            )
            let result = try await service.execute(preview.token)

            #expect(preview.distributionSlug.value == "remote-demo")
            #expect(result.status == .distributed)
            let provenance = try #require(await probe.createdPayload?.providerProvenance.first)
            #expect(provenance.skillID == preview.skillID)
            #expect(provenance.identity.provider == "clawdhub")
            #expect(provenance.identity.identifier == "remote-demo")
            #expect(provenance.version?.value == "1.2.3")
        }
    }

    @Test("blocked remote distribution still creates one managed Skill")
    func blockedStillCreates() async throws {
        try await withImportCandidate { candidate in
            let probe = ManagedLocalImportProbe(planStatuses: [.blocked])
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(),
                scope: .global
            )

            let result = try await service.execute(preview.token)

            #expect(preview.allowsBlockedCreate)
            #expect(result.status == .managedUndistributed)
            #expect(await probe.createCount == 1)
            #expect(await probe.applyCount == 0)
        }
    }

    @Test("same locator version and fingerprint is already managed")
    func duplicateIsAlreadyManaged() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                existingPayload: existing.payload,
                existingProvenance: existing.provenance
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "1.0.0"),
                scope: .agents([.claude])
            )

            let result = try await service.execute(preview.token)

            #expect(preview.skillID == existing.payload.skill.skillID)
            #expect(preview.disposition == .alreadyManaged)
            #expect(result.status == .alreadyManaged)
            #expect(await probe.createCount == 0)
            #expect(await probe.applyCount == 0)
        }
    }

    @Test("different provider version requires update without writes")
    func versionChangeRequiresUpdate() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                existingPayload: existing.payload,
                existingProvenance: existing.provenance
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "2.0.0"),
                scope: .global
            )

            let result = try await service.execute(preview.token)

            #expect(preview.disposition == .updateRequired)
            #expect(result.status == .updateRequired)
            #expect(await probe.createCount == 0)
            #expect(await probe.applyCount == 0)
        }
    }

    @Test("different content at the same version requires update without writes")
    func contentChangeRequiresUpdate() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(
                candidate: candidate,
                version: "1.0.0",
                fingerprint: SkillContentFingerprint(
                    currentDigest: Data(repeating: 0, count: 32)
                )
            )
            let probe = ManagedLocalImportProbe(
                existingPayload: existing.payload,
                existingProvenance: existing.provenance
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "1.0.0"),
                scope: .global
            )

            let result = try await service.execute(preview.token)

            #expect(preview.disposition == .updateRequired)
            #expect(result.status == .updateRequired)
            #expect(await probe.createCount == 0)
            #expect(await probe.applyCount == 0)
        }
    }

    @Test("provenance without its full domain fails closed")
    func corruptProvenanceFailsClosed() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                existingProvenance: existing.provenance
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())

            await #expect(throws: ManagedLocalImportProblem.providerConflict) {
                _ = try await service.prepareClawdhub(
                    candidate: candidate,
                    skill: remoteSkill(version: "1.0.0"),
                    scope: .global
                )
            }
        }
    }

    @Test("a concurrent unique-constraint winner is read back as already managed")
    func concurrentWinnerIsReadBack() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                createFailure: .generic,
                operationReadbackFound: false,
                existingPayload: existing.payload,
                existingProvenance: existing.provenance,
                provenanceAppearsAfterCreate: true
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "1.0.0"),
                scope: .global
            )

            let result = try await service.execute(preview.token)

            #expect(result.skillID == existing.payload.skill.skillID)
            #expect(result.status == .alreadyManaged)
            #expect(await probe.createCount == 1)
            #expect(await probe.applyCount == 0)
        }
    }

    @Test("concurrent real writer installs leave one managed Skill and no repair debt")
    func concurrentRealWriterInstallIsClean() async throws {
        try await withImportCandidate { candidate in
            let workspace = try WriterWorkspace()
            let writer = try await workspace.openWriter()
            let secondCandidate = try await SkillImportWorker().validateFolder(
                candidate.rootURL
            )
            let planProbe = ManagedLocalImportProbe(planStatuses: [.blocked])
            let dependencies = writerDependencies(writer, planProbe: planProbe)
            let first = ManagedInstallService(dependencies: dependencies)
            let second = ManagedInstallService(dependencies: dependencies)
            let skill = remoteSkill(version: "1.0.0")
            let firstPreview = try await first.prepareClawdhub(
                candidate: candidate,
                skill: skill,
                scope: .global
            )
            let secondPreview = try await second.prepareClawdhub(
                candidate: secondCandidate,
                skill: skill,
                scope: .global
            )

            let firstTask = Task { try await first.execute(firstPreview.token) }
            let secondTask = Task { try await second.execute(secondPreview.token) }
            let results = try await [firstTask.value, secondTask.value]

            #expect(Set(results.map(\.status)) == [.managedUndistributed, .alreadyManaged])
            #expect(Set(results.map(\.skillID)).count == 1)
            #expect(try workspace.integer("SELECT count(*) FROM skills") == 1)
            #expect(try workspace.integer("SELECT count(*) FROM provider_provenance") == 1)
            #expect(try workspace.integer(
                "SELECT count(*) FROM skill_operations WHERE outcome = 'needsRepair'"
            ) == 0)
            #expect(try workspace.integer("SELECT count(*) FROM skill_operations") == 1)
            #expect(try workspace.internalItemCount() == 0)
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: workspace.root.path
            ).count == 1)
        }
    }
}

private func writerDependencies(
    _ writer: JournaledSSOTWriter,
    planProbe: ManagedLocalImportProbe
) -> ManagedInstallDependencies {
    let probe = planProbe.dependencies()
    return ManagedInstallDependencies(
        plan: probe.plan,
        create: { payload, snapshot, operationID in
            try await writer.create(
                payload: payload,
                sourceSnapshot: snapshot,
                operationID: operationID
            )
        },
        createReadback: { try await writer.ssotOperationReadback($0) },
        domainReadback: { try await writer.storedDomainReadback($0)?.payload },
        provenanceReadback: { try await writer.providerProvenance($0) },
        apply: probe.apply,
        reconcile: probe.reconcile,
        nowMilliseconds: probe.nowMilliseconds
    )
}

private func remoteSkill(
    slug: String = "demo",
    version: String? = "1.0.0"
) -> RemoteSkill {
    RemoteSkill(
        id: slug,
        slug: slug,
        displayName: "Remote Demo",
        summary: nil,
        latestVersion: version,
        updatedAt: nil,
        downloads: nil,
        stars: nil
    )
}

private func existingDomain(
    candidate: SkillImportWorker.ImportCandidatePayload,
    version: String?,
    fingerprint: SkillContentFingerprint? = nil
) throws -> (
    payload: SSOTSkillWritePayload,
    provenance: ProviderProvenanceRecord
) {
    let skillID = SkillID()
    let slug = try DefaultDistributionSlug(validating: "demo")
    let skill = try ManagedSkillRecord(
        skillID: skillID,
        displayName: SkillDisplayName("Managed Demo"),
        defaultDistributionSlug: slug,
        contentFingerprint: try fingerprint ?? SkillContentFingerprint(
            currentDigest: candidate.snapshot.fingerprintDigest
        ),
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
    let provenance = try ManagedInstallProviderInput(
        slug: slug,
        version: version
    ).record(skillID: skillID)
    return (
        try SSOTSkillWritePayload(
            skill: skill,
            providerProvenance: [provenance]
        ),
        provenance
    )
}
