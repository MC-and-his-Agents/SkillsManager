import Foundation

nonisolated struct ManagedSourcePreparation: Sendable {
    let skillID: SkillID
    let displayName: SkillDisplayName
    let slug: DefaultDistributionSlug
    let scope: DistributionDesiredScope
    let disposition: ManagedLocalImportPreview.Disposition
    let baseline: ManagedSkillUpdateBaseline?
    let source: ManagedPreparedSource
}

extension ManagedInstallService {
    func prepareSourceInput(
        _ input: ManagedSourceInstallInput,
        candidate: SkillImportWorker.ImportCandidatePayload,
        requestedScope: DistributionDesiredScope
    ) async throws -> ManagedSourcePreparation {
        let existingDomain = try await dependencies.sourceReadback(
            input.repositoryURL,
            input.subpath
        )
        let aliasOwner = try await dependencies.aliasOwnerReadback(input.alias)
        guard let existingDomain else {
            guard aliasOwner == nil else {
                throw ManagedLocalImportProblem.providerAliasConflict
            }
            let skillID = SkillID()
            let sourceID = SourceID()
            return ManagedSourcePreparation(
                skillID: skillID,
                displayName: try SkillDisplayName(input.displayName),
                slug: input.distributionSlug,
                scope: requestedScope,
                disposition: .createNew,
                baseline: nil,
                source: ManagedPreparedSource(
                    input: input,
                    sourceID: sourceID,
                    admission: SourceInstallAdmissionExpectation(
                        repositoryURL: input.repositoryURL,
                        subpath: input.subpath,
                        alias: input.alias,
                        expectedSkillID: nil,
                        expectedSourceID: nil,
                        expectedAliasOwner: nil
                    )
                )
            )
        }
        return try await prepareExistingSource(
            input,
            candidate: candidate,
            domain: existingDomain,
            aliasOwner: aliasOwner
        )
    }

    private func prepareExistingSource(
        _ input: ManagedSourceInstallInput,
        candidate: SkillImportWorker.ImportCandidatePayload,
        domain: StoredSkillDomainSnapshot,
        aliasOwner: ProviderAliasSourceOwner?
    ) async throws -> ManagedSourcePreparation {
        let payload = domain.payload
        guard let source = payload.source,
              source.repositoryURL == input.repositoryURL,
              source.subpath == input.subpath else {
            throw ManagedLocalImportProblem.providerAliasConflict
        }
        guard payload.localOrigins.isEmpty else {
            throw ManagedLocalImportProblem.sourceUpdateUnsupportedLocalOrigins
        }
        if let aliasOwner, aliasOwner.sourceID != source.sourceID {
            throw ManagedLocalImportProblem.providerAliasConflict
        }
        if input.alias.provider == "github",
           payload.providerAliases.contains(where: {
               $0.identity.provider == "github" && $0.identity != input.alias
           }) {
            throw ManagedLocalImportProblem.providerAliasConflict
        }
        let hasAlias = payload.providerAliases.contains { $0.identity == input.alias }
        guard hasAlias
                || payload.providerAliases.count
                    < SSOTSkillWritePayload.maximumProviderAliasCount else {
            throw ManagedLocalImportProblem.aliasLimitReached
        }
        let baseline = try await dependencies.updateBaseline(payload.skill.skillID)
        let scope: DistributionDesiredScope
        do {
            scope = try baseline.distributionSelection.desiredScope(for: payload.skill.skillID)
        } catch {
            throw ManagedLocalImportProblem.providerAliasConflict
        }
        let fingerprint = try SkillContentFingerprint(
            currentDigest: candidate.snapshot.fingerprintDigest
        )
        let disposition: ManagedLocalImportPreview.Disposition =
            source.revision == input.revision
                && payload.skill.contentFingerprint == fingerprint
                && hasAlias
                ? .alreadyManaged : .updateRequired
        return ManagedSourcePreparation(
            skillID: payload.skill.skillID,
            displayName: payload.skill.displayName,
            slug: payload.skill.defaultDistributionSlug,
            scope: scope,
            disposition: disposition,
            baseline: baseline,
            source: ManagedPreparedSource(
                input: input,
                sourceID: source.sourceID,
                admission: SourceInstallAdmissionExpectation(
                    repositoryURL: input.repositoryURL,
                    subpath: input.subpath,
                    alias: input.alias,
                    expectedSkillID: payload.skill.skillID,
                    expectedSourceID: source.sourceID,
                    expectedAliasOwner: aliasOwner
                )
            )
        )
    }

    func createSourceBacked(
        payload: SSOTSkillWritePayload,
        snapshot: SkillContentSnapshot,
        operationID: SSOTOperationID,
        admission: SourceInstallAdmissionExpectation
    ) async -> CreateState {
        do {
            return createState(try await dependencies.createSourceBacked(
                payload,
                snapshot,
                operationID,
                admission
            ))
        } catch let createError {
            do {
                return createState(try await dependencies.operationReadback(operationID))
            } catch SSOTJournalStoreError.operationNotFound {
                return .failed(problem(for: createError))
            } catch {
                return .indeterminate
            }
        }
    }

    func unchangedSourceAdmission(
        _ admission: SourceInstallAdmissionExpectation,
        pending: Pending
    ) async throws -> Bool {
        let currentSource = try await dependencies.sourceReadback(
            admission.repositoryURL,
            admission.subpath
        )
        let currentAliasOwner = try await dependencies.aliasOwnerReadback(admission.alias)
        guard currentAliasOwner == admission.expectedAliasOwner else { return false }
        guard let expectedSkillID = admission.expectedSkillID else {
            return currentSource == nil
        }
        guard currentSource?.payload.skill.skillID == expectedSkillID,
              let expectedPayload = pending.expectedBaseline?.domain.payload,
              let currentPayload = currentSource?.payload else {
            return false
        }
        return try canonicalPayload(currentPayload) == canonicalPayload(expectedPayload)
    }
}
