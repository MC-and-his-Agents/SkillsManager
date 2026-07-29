import Foundation

extension ManagedSkillUpdateExecutionService {
    func replace(
        preview: ManagedLocalImportPreview,
        baseline: ManagedSkillUpdateBaseline,
        prepared: ManagedSkillPreparedCandidate,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) async throws -> ManagedLocalImportResult {
        switch prepared.candidate.locator {
        case .clawdhub(let slug, let version):
            return try await remoteUpdate.execute(
                preview: preview,
                baseline: baseline,
                providerInput: ManagedInstallProviderInput(
                    slug: try DefaultDistributionSlug(validating: slug),
                    version: version.value
                ),
                candidate: prepared.payload,
                operationID: operationID,
                backupID: backupID
            )
        case .github(let repositoryURL, let subpath, let revision, let downloadURL):
            let payload = baseline.domain.payload
            guard let source = payload.source,
                  source.repositoryURL == repositoryURL,
                  source.subpath == subpath,
                  let alias = payload.providerAliases.first(where: {
                      $0.sourceID == source.sourceID
                  }) else {
                throw ManagedSkillUpdateExecutionProblem.stale
            }
            let aliasOwner = try await writer.providerAliasOwnerReadback(alias.identity)
            let input = ManagedSourceInstallInput(
                displayName: payload.skill.displayName.value,
                distributionSlug: payload.skill.defaultDistributionSlug,
                repositoryURL: repositoryURL,
                subpath: subpath,
                revision: revision,
                downloadURL: downloadURL,
                alias: alias.identity,
                refreshHead: { revision }
            )
            return try await remoteUpdate.execute(
                preview: preview,
                baseline: baseline,
                preparedSource: ManagedPreparedSource(
                    input: input,
                    sourceID: source.sourceID,
                    admission: SourceInstallAdmissionExpectation(
                        repositoryURL: repositoryURL,
                        subpath: subpath,
                        alias: alias.identity,
                        expectedSkillID: payload.skill.skillID,
                        expectedSourceID: source.sourceID,
                        expectedAliasOwner: aliasOwner
                    )
                ),
                candidate: prepared.payload,
                operationID: operationID,
                backupID: backupID
            )
        }
    }

    func replacementApplied(
        skillID: SkillID,
        candidate: ManagedSkillUpdateCandidate,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) async throws -> Bool {
        let operation = try await writer.ssotOperationReadback(operationID)
        guard operation.state.phase == .completed,
              operation.state.outcome == .applied,
              let backup = try await writer.updateBackupReadback(backupID),
              backup.state == .available,
              backup.originalSkillID == skillID else {
            return false
        }
        let current = try await writer.updateCheckReadback(skillID: skillID)
        let storedCheck = try await writer.loadUpdateCheck(skillID)
        return current.domain.payload.skill.contentFingerprint
                == candidate.contentFingerprint
            && current.liveFingerprint == candidate.contentFingerprint
            && storedCheck == nil
    }

    func finishDistributionAndCheck(
        skillID: SkillID,
        candidate: ManagedSkillUpdateCandidate
    ) async -> ManagedSkillUpdateExecutionStatus {
        do {
            let selection = try await distribution.loadSelection(skillID)
            let configuration = try selection.desiredConfiguration(for: skillID)
            if case .disabled = configuration.scope {
                guard try await distribution.reconcile(skillID).status == .inSync else {
                    return .updatedNeedsAttention
                }
            } else {
                let plan = try await distribution.plan(
                    skillID,
                    configuration,
                    configuration.scope.requiredAdapterCodes
                )
                switch plan.status {
                case .blocked:
                    return .updatedNeedsAttention
                case .executable:
                    let operation = try await distribution.apply(skillID, plan)
                    guard operation.phase == .completed,
                          operation.outcome == .applied else {
                        return .updatedNeedsAttention
                    }
                case .noOp:
                    break
                }
                guard try await distribution.reconcile(skillID).status == .inSync else {
                    return .updatedNeedsAttention
                }
            }
            let snapshot = try await checks.recordValidatedCandidate(
                skillID: skillID,
                candidate: candidate
            )
            return snapshot.status == .upToDate ? .updated : .updatedNeedsAttention
        } catch {
            if Self.problem(for: error) == .needsRepair {
                return .needsRepair
            }
            return .updatedNeedsAttention
        }
    }

    func classifyFailure(
        _ error: Error,
        skillID: SkillID,
        expectedUnupdated: ManagedSkillUpdateCheckReadback,
        durableCopyDecision: Bool,
        copyMutationAttempted: Bool,
        operationID: SSOTOperationID?,
        backupID: SkillBackupID?
    ) async throws -> ManagedSkillUpdateExecutionResult {
        if let operationID,
           let operationResult = await replacementFailureResult(
               skillID: skillID,
               operationID: operationID,
               backupID: backupID
           ) {
            return operationResult
        }
        if let backupID,
           let backup = try? await writer.updateBackupReadback(backupID),
           backup.state == .available,
           let current = try? await writer.updateCheckReadback(skillID: skillID),
           current.canonicalData == expectedUnupdated.canonicalData {
            return result(
                skillID: skillID,
                status: durableCopyDecision
                    ? .copyDecisionsAppliedUpdateNotCompleted
                    : .backupReadyUpdateNotStarted,
                backupID: backupID
            )
        }
        if durableCopyDecision {
            return result(
                skillID: skillID,
                status: .copyDecisionsAppliedUpdateNotCompleted,
                backupID: backupID
            )
        }
        if copyMutationAttempted {
            if let current = try? await writer.updateCheckReadback(skillID: skillID) {
                if current.distributionStatus == .needsRepair {
                    return result(skillID: skillID, status: .needsRepair, backupID: backupID)
                }
                if current.canonicalData != expectedUnupdated.canonicalData {
                    return result(
                        skillID: skillID,
                        status: .copyDecisionsAppliedUpdateNotCompleted,
                        backupID: backupID
                    )
                }
            }
            return result(
                skillID: skillID,
                status: .updateIndeterminate,
                backupID: backupID
            )
        }
        if error is CancellationError
            || (error as? ManagedSkillUpdateCheckProblem) == .cancelled {
            return result(skillID: skillID, status: .cancelled)
        }
        throw Self.problem(for: error)
    }

    private func replacementFailureResult(
        skillID: SkillID,
        operationID: SSOTOperationID,
        backupID: SkillBackupID?
    ) async -> ManagedSkillUpdateExecutionResult? {
        do {
            let operation = try await writer.ssotOperationReadback(operationID)
            if operation.state.outcome == .needsRepair
                || operation.state.cleanupState == .needsRepair {
                return result(skillID: skillID, status: .needsRepair, backupID: backupID)
            }
            guard operation.state.phase == .completed else {
                return result(
                    skillID: skillID,
                    status: .updateIndeterminate,
                    backupID: backupID
                )
            }
            let status: ManagedSkillUpdateExecutionStatus = switch operation.state.outcome {
            case .applied: .updatedNeedsAttention
            case .rolledBack: .updateRolledBack
            case .needsRepair: .needsRepair
            case .pending: .updateIndeterminate
            }
            return result(skillID: skillID, status: status, backupID: backupID)
        } catch SSOTJournalStoreError.operationNotFound {
            return nil
        } catch {
            return result(
                skillID: skillID,
                status: .updateIndeterminate,
                backupID: backupID
            )
        }
    }

    func result(
        skillID: SkillID,
        status: ManagedSkillUpdateExecutionStatus,
        backupID: SkillBackupID? = nil
    ) -> ManagedSkillUpdateExecutionResult {
        ManagedSkillUpdateExecutionResult(
            skillID: skillID,
            status: status,
            backupID: backupID
        )
    }

    nonisolated static func problem(
        for error: Error
    ) -> ManagedSkillUpdateExecutionProblem {
        if let value = error as? ManagedSkillUpdateExecutionProblem {
            return value
        }
        if let value = error as? ManagedSkillUpdateCheckProblem {
            return switch value {
            case .stale: .stale
            case .unavailable: .unavailable
            case .unsafeContent: .failed
            case .timeout, .offline, .rateLimited, .providerUnavailable: .providerUnavailable
            case .databaseUnavailable, .failed, .cancelled: .failed
            }
        }
        if let value = managedInstallKnownProblem(for: error) {
            return switch value {
            case .permissionDenied: .permissionDenied
            case .needsRepair, .operationInProgress: .needsRepair
            case .previewExpired, .sourceChanged, .providerConflict,
                 .providerAliasConflict: .stale
            default: .failed
            }
        }
        if error is CopyForkError {
            return .unsafeCopyState
        }
        return .failed
    }
}
