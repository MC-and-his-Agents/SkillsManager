import Foundation

struct ManagedRemoteUpdateService: Sendable {
    private enum WriteState {
        case committed
        case failed(ManagedLocalImportProblem)
        case indeterminate
    }

    let dependencies: ManagedInstallDependencies

    func execute(
        preview: ManagedLocalImportPreview,
        baseline: ManagedSkillUpdateBaseline,
        providerInput: ManagedInstallProviderInput,
        candidate: SkillImportWorker.ImportCandidatePayload,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) async throws -> ManagedLocalImportResult {
        let replacement = try replacementPayload(
            baseline: baseline,
            providerInput: providerInput,
            snapshot: candidate.snapshot
        )
        switch await replaceWithBackup(
            baseline: baseline,
            replacement: replacement,
            snapshot: candidate.snapshot,
            operationID: operationID,
            backupID: backupID,
            sourceAdmission: nil
        ) {
        case .committed:
            return await reconciledResult(preview)
        case .failed(let problem):
            throw problem
        case .indeterminate:
            return result(preview, status: .updateIndeterminate)
        }
    }

    func execute(
        preview: ManagedLocalImportPreview,
        baseline: ManagedSkillUpdateBaseline,
        preparedSource: ManagedPreparedSource,
        candidate: SkillImportWorker.ImportCandidatePayload,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) async throws -> ManagedLocalImportResult {
        let replacement = try sourceReplacementPayload(
            baseline: baseline,
            preparedSource: preparedSource,
            snapshot: candidate.snapshot
        )
        switch await replaceWithBackup(
            baseline: baseline,
            replacement: replacement,
            snapshot: candidate.snapshot,
            operationID: operationID,
            backupID: backupID,
            sourceAdmission: preparedSource.admission
        ) {
        case .committed:
            return await reconciledResult(preview)
        case .failed(let problem):
            throw problem
        case .indeterminate:
            return result(preview, status: .updateIndeterminate)
        }
    }

    private func replaceWithBackup(
        baseline: ManagedSkillUpdateBaseline,
        replacement: SSOTSkillWritePayload,
        snapshot: SkillContentSnapshot,
        operationID: SSOTOperationID,
        backupID: SkillBackupID,
        sourceAdmission: SourceInstallAdmissionExpectation?
    ) async -> WriteState {
        do {
            let write: ManagedSkillUpdateWriteResult
            if let sourceAdmission {
                write = try await dependencies.replaceSourceBackedWithBackup(
                    baseline,
                    replacement,
                    snapshot,
                    operationID,
                    backupID,
                    sourceAdmission
                )
            } else {
                write = try await dependencies.replaceWithBackup(
                    baseline,
                    replacement,
                    snapshot,
                    operationID,
                    backupID
                )
            }
            return state(write.replacement)
        } catch let updateError {
            do {
                return state(try await dependencies.operationReadback(operationID))
            } catch SSOTJournalStoreError.operationNotFound {
                return await stateWithoutJournal(
                    baseline: baseline,
                    replacement: replacement,
                    updateError: updateError
                )
            } catch {
                return .indeterminate
            }
        }
    }

    private func stateWithoutJournal(
        baseline: ManagedSkillUpdateBaseline,
        replacement: SSOTSkillWritePayload,
        updateError: Error
    ) async -> WriteState {
        do {
            guard let current = try await dependencies.domainReadback(
                replacement.skill.skillID
            ) else {
                return .indeterminate
            }
            let canonicalCurrent = try canonicalPayload(current)
            if canonicalCurrent == (try canonicalPayload(replacement)) {
                return .committed
            }
            if canonicalCurrent == (try canonicalPayload(baseline.domain.payload)) {
                return .failed(problem(for: updateError))
            }
            return .failed(.needsRepair)
        } catch {
            return .indeterminate
        }
    }

    private func state(_ record: SSOTJournalRecord) -> WriteState {
        if record.state.outcome == .needsRepair || record.state.cleanupState == .needsRepair {
            return .failed(.needsRepair)
        }
        guard record.state.phase == .completed else { return .indeterminate }
        switch record.state.outcome {
        case .applied:
            return .committed
        case .rolledBack:
            return .failed(.updateRolledBack)
        case .needsRepair:
            return .failed(.needsRepair)
        case .pending:
            return .indeterminate
        }
    }

    private func replacementPayload(
        baseline: ManagedSkillUpdateBaseline,
        providerInput: ManagedInstallProviderInput,
        snapshot: SkillContentSnapshot
    ) throws -> SSOTSkillWritePayload {
        let old = baseline.domain.payload
        guard old.localOrigins.isEmpty,
              old.providerProvenance.contains(where: {
                  $0.identity == providerInput.identity
                      && $0.identifierKey == providerInput.identifierKey
              }),
              old.skill.updatedAtMilliseconds < Int64.max else {
            throw ManagedLocalImportProblem.providerConflict
        }
        let updatedSkill = try ManagedSkillRecord(
            skillID: old.skill.skillID,
            displayName: old.skill.displayName,
            defaultDistributionSlug: old.skill.defaultDistributionSlug,
            contentFingerprint: SkillContentFingerprint(
                currentDigest: snapshot.fingerprintDigest
            ),
            status: old.skill.status,
            createdAtMilliseconds: old.skill.createdAtMilliseconds,
            updatedAtMilliseconds: max(
                old.skill.updatedAtMilliseconds + 1,
                max(0, dependencies.nowMilliseconds())
            )
        )
        let updatedProvenance = try old.providerProvenance.map { record in
            if record.identity == providerInput.identity {
                return try providerInput.record(skillID: old.skill.skillID)
            }
            return record
        }
        return try SSOTSkillWritePayload(
            skill: updatedSkill,
            source: old.source,
            providerAliases: old.providerAliases,
            providerProvenance: updatedProvenance,
            localOrigins: old.localOrigins,
            restoredFromSkillID: old.restoredFromSkillID
        )
    }

    private func sourceReplacementPayload(
        baseline: ManagedSkillUpdateBaseline,
        preparedSource: ManagedPreparedSource,
        snapshot: SkillContentSnapshot
    ) throws -> SSOTSkillWritePayload {
        let old = baseline.domain.payload
        guard old.localOrigins.isEmpty else {
            throw ManagedLocalImportProblem.sourceUpdateUnsupportedLocalOrigins
        }
        guard let oldSource = old.source,
              oldSource.sourceID == preparedSource.sourceID,
              oldSource.repositoryURL == preparedSource.input.repositoryURL,
              oldSource.subpath == preparedSource.input.subpath,
              old.skill.updatedAtMilliseconds < Int64.max else {
            throw ManagedLocalImportProblem.previewExpired
        }
        var aliases = old.providerAliases
        if !aliases.contains(where: { $0.identity == preparedSource.input.alias }) {
            guard aliases.count < SSOTSkillWritePayload.maximumProviderAliasCount else {
                throw ManagedLocalImportProblem.aliasLimitReached
            }
            aliases.append(ProviderAliasRecord(
                sourceID: oldSource.sourceID,
                identity: preparedSource.input.alias
            ))
        }
        let updatedSkill = try ManagedSkillRecord(
            skillID: old.skill.skillID,
            displayName: old.skill.displayName,
            defaultDistributionSlug: old.skill.defaultDistributionSlug,
            contentFingerprint: SkillContentFingerprint(
                currentDigest: snapshot.fingerprintDigest
            ),
            status: old.skill.status,
            createdAtMilliseconds: old.skill.createdAtMilliseconds,
            updatedAtMilliseconds: max(
                old.skill.updatedAtMilliseconds + 1,
                max(0, dependencies.nowMilliseconds())
            )
        )
        return try SSOTSkillWritePayload(
            skill: updatedSkill,
            source: SkillSourceRecord(
                sourceID: oldSource.sourceID,
                skillID: old.skill.skillID,
                repositoryURL: oldSource.repositoryURL,
                subpath: oldSource.subpath,
                revision: preparedSource.input.revision,
                version: oldSource.version,
                downloadURL: preparedSource.input.downloadURL
            ),
            providerAliases: aliases,
            providerProvenance: old.providerProvenance,
            localOrigins: [],
            restoredFromSkillID: old.restoredFromSkillID,
            forkLineage: old.forkLineage
        )
    }

    private func reconciledResult(
        _ preview: ManagedLocalImportPreview
    ) async -> ManagedLocalImportResult {
        guard let reconcile = try? await dependencies.reconcile(preview.skillID) else {
            return result(preview, status: .updatedDistributionNeedsAttention)
        }
        switch reconcile.status {
        case .inSync:
            return result(preview, status: .updated)
        case .drifted, .needsRepair, .operationInProgress:
            return result(preview, status: .updatedDistributionNeedsAttention)
        }
    }

    private func problem(for error: Error) -> ManagedLocalImportProblem {
        if let problem = error as? ManagedLocalImportProblem {
            return problem
        }
        if error is CancellationError {
            return .updateFailed("Update was cancelled.")
        }
        guard let known = managedInstallKnownProblem(for: error) else {
            return .updateFailed(error.localizedDescription)
        }
        if case .failed(let detail) = known {
            return .updateFailed(detail)
        }
        return known
    }

    private func canonicalPayload(_ payload: SSOTSkillWritePayload) throws -> Data {
        try SSOTWritePayloadCodec.encode(payload)
    }

    private func result(
        _ preview: ManagedLocalImportPreview,
        status: ManagedLocalImportResultStatus
    ) -> ManagedLocalImportResult {
        ManagedLocalImportResult(
            skillID: preview.skillID,
            displayName: preview.displayName.value,
            status: status
        )
    }
}
