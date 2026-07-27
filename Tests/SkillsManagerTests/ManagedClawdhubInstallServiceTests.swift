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
