import Foundation

extension ManagedInstallService {
    func unchangedExistingPayload(_ pending: Pending) async throws -> Bool {
        guard let expectedPayload = pending.expectedBaseline?.domain.payload,
              let current = try await dependencies.domainReadback(
                  pending.preview.skillID
              ) else {
            return false
        }
        return try canonicalPayload(current) == canonicalPayload(expectedPayload)
    }

    func remoteDisposition(
        existing: ProviderProvenanceRecord,
        payload: SSOTSkillWritePayload,
        input: ManagedInstallProviderInput,
        candidate: SkillImportWorker.ImportCandidatePayload
    ) throws -> ManagedLocalImportPreview.Disposition {
        guard existing.identifierKey == input.identifierKey,
              payload.providerProvenance.contains(existing) else {
            throw ManagedLocalImportProblem.providerConflict
        }
        let candidateFingerprint = try SkillContentFingerprint(
            currentDigest: candidate.snapshot.fingerprintDigest
        )
        return existing.version == input.version
            && payload.skill.contentFingerprint == candidateFingerprint
            ? .alreadyManaged : .updateRequired
    }
}
