import Foundation

actor ManagedSkillUpdateExecutionService {
    private struct Pending {
        let preview: ManagedSkillUpdateExecutionPreview
        let snapshot: ManagedSkillUpdateCheckSnapshot
        let readback: ManagedSkillUpdateCheckReadback
        let prepared: ManagedSkillPreparedCandidate
        let copyPreviews: [String: CopyDriftDecisionPreview]
    }

    let writer: JournaledSSOTWriter
    let checks: ManagedSkillUpdateCheckService
    let distribution: SkillDistributionDependencies
    let remoteUpdate: ManagedRemoteUpdateService
    private var pending: [ManagedSkillUpdateExecutionToken: Pending] = [:]
    private var consumed: Set<ManagedSkillUpdateExecutionToken> = []

    init(
        writer: JournaledSSOTWriter,
        remote: RemoteSkillClient,
        github: SkillsShGitHubSourceClient = .live()
    ) {
        self.writer = writer
        checks = ManagedSkillUpdateCheckService(
            writer: writer,
            remote: remote,
            github: github
        )
        distribution = .live(writer: writer)
        remoteUpdate = ManagedRemoteUpdateService(
            dependencies: .live(writer: writer)
        )
    }

    func prepare(
        _ snapshot: ManagedSkillUpdateCheckSnapshot
    ) async throws -> ManagedSkillUpdateExecutionPreview {
        guard let persisted = try await writer.loadUpdateCheck(snapshot.skillID),
              persisted == snapshot,
              let candidate = snapshot.candidate else {
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        let readback = try await writer.updateCheckReadback(skillID: snapshot.skillID)
        guard readback.liveFingerprint == snapshot.liveFingerprint,
              candidate.contentFingerprint != readback.liveFingerprint,
              snapshot.status == .remoteChanged || snapshot.status == .copyDrift else {
            throw ManagedSkillUpdateExecutionProblem.noUpdate
        }
        let selection = try await writer.loadDistributionSelection(skillID: snapshot.skillID)
        _ = try selection.desiredConfiguration(for: snapshot.skillID)
        let copyPreviews = try await prepareCopyPreviews(
            snapshot: snapshot,
            selection: selection
        )
        let prepared: ManagedSkillPreparedCandidate
        do {
            prepared = try await checks.prepareCandidate(for: readback.domain)
        } catch {
            throw Self.problem(for: error)
        }
        guard prepared.candidate == candidate else {
            await checks.cleanup(prepared)
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        let final = try await writer.updateCheckReadback(skillID: snapshot.skillID)
        guard final.canonicalData == readback.canonicalData else {
            await checks.cleanup(prepared)
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        let token = ManagedSkillUpdateExecutionToken()
        let choices = copyPreviews.values.sorted {
            $0.binding.scope.targetScopeKey.utf8.lexicographicallyPrecedes(
                $1.binding.scope.targetScopeKey.utf8
            )
        }.map {
            ManagedSkillUpdateCopyChoice(
                scopeKey: $0.binding.scope.targetScopeKey,
                targetDescription: DistributionTargetCatalog.current.entry(
                    for: $0.binding.scope,
                    slug: $0.binding.distributionSlug
                )?.canonicalLocator ?? $0.binding.scope.targetScopeKey
            )
        }
        let preview = ManagedSkillUpdateExecutionPreview(
            token: token,
            skillID: snapshot.skillID,
            displayName: readback.domain.payload.skill.displayName.value,
            sourceDescription: candidate.locator.updateDisplayName,
            currentFingerprint: readback.domain.payload.skill.contentFingerprint,
            candidate: candidate,
            copyChoices: choices
        )
        pending[token] = Pending(
            preview: preview,
            snapshot: snapshot,
            readback: readback,
            prepared: prepared,
            copyPreviews: copyPreviews
        )
        return preview
    }

    func cancel(_ token: ManagedSkillUpdateExecutionToken) async {
        guard let value = pending.removeValue(forKey: token) else { return }
        await checks.cleanup(value.prepared)
    }

    func confirm(
        _ token: ManagedSkillUpdateExecutionToken,
        selections: [ManagedSkillUpdateDecisionSelection]
    ) async throws -> ManagedSkillUpdateExecutionResult {
        guard !consumed.contains(token),
              let value = pending.removeValue(forKey: token) else {
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        consumed.insert(token)
        let decisions: [String: ManagedSkillUpdateCopyDecision]
        do {
            decisions = try decisionMap(selections, expected: value.copyPreviews.keys)
        } catch {
            await checks.cleanup(value.prepared)
            throw error
        }
        if decisions.values.contains(.cancel) {
            await checks.cleanup(value.prepared)
            return result(skillID: value.preview.skillID, status: .cancelled)
        }
        return try await performConfirmedUpdate(value, decisions: decisions)
    }

    private func performConfirmedUpdate(
        _ value: Pending,
        decisions: [String: ManagedSkillUpdateCopyDecision]
    ) async throws -> ManagedSkillUpdateExecutionResult {
        var durableCopyDecision = false
        var copyMutationAttempted = false
        var replacementOperationID: SSOTOperationID?
        var backupID: SkillBackupID?
        var prepared = value.prepared
        var expectedUnupdated = value.readback
        do {
            prepared = try await refreshedCandidate(
                replacing: prepared,
                domain: value.readback.domain,
                expected: value.preview.candidate
            )
            var expected = try await requireCurrent(
                skillID: value.preview.skillID,
                expectedCanonicalData: value.readback.canonicalData
            )
            expectedUnupdated = expected
            for scopeKey in value.copyPreviews.keys.sorted(by: utf8Precedes) {
                guard let approved = value.copyPreviews[scopeKey],
                      let decision = decisions[scopeKey] else {
                    throw ManagedSkillUpdateExecutionProblem.invalidDecisions
                }
                copyMutationAttempted = true
                expected = try await executeCopyDecision(
                    approved: approved,
                    decision: decision,
                    expected: expected
                )
                durableCopyDecision = true
                expectedUnupdated = expected
            }
            if durableCopyDecision {
                prepared = try await refreshedCandidate(
                    replacing: prepared,
                    domain: expected.domain,
                    expected: value.preview.candidate
                )
                expected = try await requireCurrent(
                    skillID: value.preview.skillID,
                    expectedCanonicalData: expected.canonicalData
                )
                expectedUnupdated = expected
            }
            let operationID = SSOTOperationID()
            let newBackupID = SkillBackupID()
            replacementOperationID = operationID
            backupID = newBackupID
            let result = try await replaceParentSkill(
                value: value,
                expected: expected,
                prepared: prepared,
                operationID: operationID,
                backupID: newBackupID
            )
            await checks.cleanup(prepared)
            return result
        } catch {
            await checks.cleanup(prepared)
            return try await classifyFailure(
                error,
                skillID: value.preview.skillID,
                expectedUnupdated: expectedUnupdated,
                durableCopyDecision: durableCopyDecision,
                copyMutationAttempted: copyMutationAttempted,
                operationID: replacementOperationID,
                backupID: backupID
            )
        }
    }

    private func replaceParentSkill(
        value: Pending,
        expected: ManagedSkillUpdateCheckReadback,
        prepared: ManagedSkillPreparedCandidate,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) async throws -> ManagedSkillUpdateExecutionResult {
        let skillID = value.preview.skillID
        let baseline = try await writer.managedSkillUpdateBaseline(skillID)
        try requireBaseline(baseline, matches: expected)
        let configuration = try baseline.distributionSelection
            .desiredConfiguration(for: skillID)
        let plan = try await distribution.plan(
            skillID,
            configuration,
            configuration.scope.requiredAdapterCodes
        )
        guard plan.status != .blocked else {
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        let importPreview = ManagedLocalImportPreview(
            token: ManagedLocalImportToken(),
            skillID: skillID,
            displayName: baseline.domain.payload.skill.displayName,
            distributionSlug: baseline.domain.payload.skill.defaultDistributionSlug,
            desiredScope: configuration.scope,
            plan: plan,
            disposition: .updateRequired,
            allowsBlockedCreate: false,
            source: nil
        )
        let write = try await replace(
            preview: importPreview,
            baseline: baseline,
            prepared: prepared,
            operationID: operationID,
            backupID: backupID
        )
        guard write.status == .updated
                || write.status == .updatedDistributionNeedsAttention,
              try await replacementApplied(
                skillID: skillID,
                candidate: value.preview.candidate,
                operationID: operationID,
                backupID: backupID
              ) else {
            return result(
                skillID: skillID,
                status: .updateIndeterminate,
                backupID: backupID
            )
        }
        return result(
            skillID: skillID,
            status: await finishDistributionAndCheck(
                skillID: skillID,
                candidate: value.preview.candidate
            ),
            backupID: backupID
        )
    }

    private func prepareCopyPreviews(
        snapshot: ManagedSkillUpdateCheckSnapshot,
        selection: DistributionSelectionReadback
    ) async throws -> [String: CopyDriftDecisionPreview] {
        var result: [String: CopyDriftDecisionPreview] = [:]
        for state in snapshot.copyStates where state.isTargetDrift {
            guard state.state == .contentDrift,
                  result[state.scopeKey] == nil,
                  let binding = selection.bindings.first(where: {
                      $0.scope.targetScopeKey == state.scopeKey
                  }),
                  binding.syncMode == .copy else {
                throw ManagedSkillUpdateExecutionProblem.unsafeCopyState
            }
            result[state.scopeKey] = try await distribution.copyDriftPreview(
                snapshot.skillID,
                binding.scope
            )
        }
        return result
    }

    private func decisionMap(
        _ selections: [ManagedSkillUpdateDecisionSelection],
        expected: Dictionary<String, CopyDriftDecisionPreview>.Keys
    ) throws -> [String: ManagedSkillUpdateCopyDecision] {
        let pairs = selections.map { ($0.scopeKey, $0.decision) }
        guard Set(pairs.map(\.0)).count == pairs.count else {
            throw ManagedSkillUpdateExecutionProblem.invalidDecisions
        }
        let result = Dictionary(uniqueKeysWithValues: pairs)
        guard Set(result.keys) == Set(expected) else {
            throw ManagedSkillUpdateExecutionProblem.invalidDecisions
        }
        return result
    }

    private func refreshedCandidate(
        replacing old: ManagedSkillPreparedCandidate,
        domain: StoredSkillDomainSnapshot,
        expected: ManagedSkillUpdateCandidate
    ) async throws -> ManagedSkillPreparedCandidate {
        let fresh: ManagedSkillPreparedCandidate
        do {
            fresh = try await checks.prepareCandidate(for: domain)
        } catch {
            throw Self.problem(for: error)
        }
        guard fresh.candidate == expected else {
            await checks.cleanup(fresh)
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        await checks.cleanup(old)
        return fresh
    }

    private func requireCurrent(
        skillID: SkillID,
        expectedCanonicalData: Data
    ) async throws -> ManagedSkillUpdateCheckReadback {
        let current = try await writer.updateCheckReadback(skillID: skillID)
        guard current.canonicalData == expectedCanonicalData else {
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        return current
    }

    private func executeCopyDecision(
        approved: CopyDriftDecisionPreview,
        decision: ManagedSkillUpdateCopyDecision,
        expected: ManagedSkillUpdateCheckReadback
    ) async throws -> ManagedSkillUpdateCheckReadback {
        let current = try await requireCurrent(
            skillID: approved.forkPreview.parentSkillID,
            expectedCanonicalData: expected.canonicalData
        )
        let fresh = try await distribution.copyDriftPreview(
            approved.forkPreview.parentSkillID,
            approved.binding.scope
        )
        guard sameDecisionEvidence(fresh, approved) else {
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        switch decision {
        case .discard:
            let operation = try await distribution.discardCopyDrift(fresh)
            guard operation.phase == .completed, operation.outcome == .applied else {
                throw ManagedSkillUpdateExecutionProblem.needsRepair
            }
        case .fork:
            let fork = try await distribution.createCopyFork(fresh)
            guard fork.parentSkillID == approved.forkPreview.parentSkillID,
                  fork.scope == approved.binding.scope,
                  let child = try await writer.storedDomainReadback(fork.childSkillID),
                  child.payload.forkLineage?.parentSkillID == fork.parentSkillID else {
                throw ManagedSkillUpdateExecutionProblem.needsRepair
            }
        case .cancel:
            throw ManagedSkillUpdateExecutionProblem.invalidDecisions
        }
        let after = try await writer.updateCheckReadback(
            skillID: approved.forkPreview.parentSkillID
        )
        try requireApprovedCopyTransition(
            before: current,
            after: after,
            scopeKey: approved.binding.scope.targetScopeKey,
            decision: decision
        )
        return after
    }

    private func sameDecisionEvidence(
        _ lhs: CopyDriftDecisionPreview,
        _ rhs: CopyDriftDecisionPreview
    ) -> Bool {
        lhs.parentRevision == rhs.parentRevision
            && lhs.binding == rhs.binding
            && lhs.observedEvidence == rhs.observedEvidence
            && lhs.sourceEvidence == rhs.sourceEvidence
            && lhs.forkPreview.parentSkillID == rhs.forkPreview.parentSkillID
            && lhs.forkPreview.scope == rhs.forkPreview.scope
            && lhs.forkPreview.distributionSlug == rhs.forkPreview.distributionSlug
            && lhs.forkPreview.contentFingerprint == rhs.forkPreview.contentFingerprint
    }

    private func requireApprovedCopyTransition(
        before: ManagedSkillUpdateCheckReadback,
        after: ManagedSkillUpdateCheckReadback,
        scopeKey: String,
        decision: ManagedSkillUpdateCopyDecision
    ) throws {
        guard before.domain.revision == after.domain.revision,
              try SSOTWritePayloadCodec.encode(before.domain.payload)
                == SSOTWritePayloadCodec.encode(after.domain.payload),
              before.liveSSOTIdentity == after.liveSSOTIdentity,
              before.liveFingerprint == after.liveFingerprint else {
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        let oldOthers = before.copyStates.filter { $0.scopeKey != scopeKey }
        let newOthers = after.copyStates.filter { $0.scopeKey != scopeKey }
        guard oldOthers == newOthers else {
            throw ManagedSkillUpdateExecutionProblem.stale
        }
        switch decision {
        case .discard:
            guard after.copyStates.first(where: { $0.scopeKey == scopeKey })?.state == .inSync
            else { throw ManagedSkillUpdateExecutionProblem.needsRepair }
        case .fork:
            guard !after.copyStates.contains(where: { $0.scopeKey == scopeKey })
            else { throw ManagedSkillUpdateExecutionProblem.needsRepair }
        case .cancel:
            throw ManagedSkillUpdateExecutionProblem.invalidDecisions
        }
    }

    private func requireBaseline(
        _ baseline: ManagedSkillUpdateBaseline,
        matches readback: ManagedSkillUpdateCheckReadback
    ) throws {
        guard baseline.domain.revision == readback.domain.revision,
              try SSOTWritePayloadCodec.encode(baseline.domain.payload)
                == SSOTWritePayloadCodec.encode(readback.domain.payload),
              baseline.finalIdentity == readback.liveSSOTIdentity else {
            throw ManagedSkillUpdateExecutionProblem.stale
        }
    }
}
