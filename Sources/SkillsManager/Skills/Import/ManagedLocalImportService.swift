import Darwin
import Foundation

actor ManagedInstallService {
    struct Pending: Sendable {
        let preview: ManagedLocalImportPreview
        let operationID: SSOTOperationID
        let backupID: SkillBackupID
        let candidate: SkillImportWorker.ImportCandidatePayload
        let providerInput: ManagedInstallProviderInput?
        let preparedSource: ManagedPreparedSource?
        let expectedBaseline: ManagedSkillUpdateBaseline?
        let canonicalPlan: Data
    }

    private enum State: Sendable {
        case pending(Pending)
        case executing
        case completed(ManagedLocalImportResult)
        case failed(ManagedLocalImportProblem)
    }

    let dependencies: ManagedInstallDependencies
    private var states: [ManagedLocalImportToken: State] = [:]

    init(dependencies: ManagedInstallDependencies) {
        self.dependencies = dependencies
    }

    func prepare(
        candidate: SkillImportWorker.ImportCandidatePayload,
        displayName rawDisplayName: String,
        scope: ManagedLocalImportScope
    ) async throws -> ManagedLocalImportPreview {
        try await prepare(
            candidate: candidate,
            displayName: rawDisplayName,
            distributionSlug: nil,
            scope: scope,
            providerInput: nil,
            allowsBlockedCreate: false
        )
    }

    func prepareArchive(
        candidate: SkillImportWorker.ImportCandidatePayload,
        displayName rawDisplayName: String,
        scope: ManagedLocalImportScope
    ) async throws -> ManagedLocalImportPreview {
        try await prepare(
            candidate: candidate,
            displayName: rawDisplayName,
            distributionSlug: nil,
            scope: scope,
            providerInput: nil,
            allowsBlockedCreate: true
        )
    }

    func prepareClawdhub(
        candidate: SkillImportWorker.ImportCandidatePayload,
        skill: RemoteSkill,
        scope: ManagedLocalImportScope
    ) async throws -> ManagedLocalImportPreview {
        let slug = try DefaultDistributionSlug(validating: skill.slug)
        return try await prepare(
            candidate: candidate,
            displayName: skill.displayName,
            distributionSlug: slug,
            scope: scope,
            providerInput: try ManagedInstallProviderInput(
                slug: slug,
                version: skill.latestVersion
            ),
            allowsBlockedCreate: true
        )
    }

    func prepareSourceBacked(
        candidate: SkillImportWorker.ImportCandidatePayload,
        sourceInput: ManagedSourceInstallInput,
        scope: ManagedLocalImportScope
    ) async throws -> ManagedLocalImportPreview {
        try await prepare(
            candidate: candidate,
            displayName: sourceInput.displayName,
            distributionSlug: sourceInput.distributionSlug,
            scope: scope,
            providerInput: nil,
            sourceInput: sourceInput,
            allowsBlockedCreate: true
        )
    }

    private func prepare(
        candidate: SkillImportWorker.ImportCandidatePayload,
        displayName rawDisplayName: String,
        distributionSlug: DefaultDistributionSlug?,
        scope: ManagedLocalImportScope,
        providerInput: ManagedInstallProviderInput?,
        sourceInput: ManagedSourceInstallInput? = nil,
        allowsBlockedCreate: Bool
    ) async throws -> ManagedLocalImportPreview {
        guard providerInput == nil || sourceInput == nil else {
            throw ManagedLocalImportProblem.invalidCandidate
        }
        guard candidate.snapshot.fingerprint == candidate.fingerprint else {
            throw ManagedLocalImportProblem.invalidCandidate
        }
        var displayName = try SkillDisplayName(rawDisplayName)
        var slug = try distributionSlug ?? DefaultDistributionSlug(candidateFrom: displayName)
        var skillID = SkillID()
        var disposition: ManagedLocalImportPreview.Disposition = .createNew
        var expectedBaseline: ManagedSkillUpdateBaseline?
        var preparedSource: ManagedPreparedSource?
        var resolvedScope = try scope.desiredScope(slug: slug)
        if let providerInput,
           let existing = try await dependencies.provenanceReadback(providerInput.identity) {
            let baseline: ManagedSkillUpdateBaseline
            do {
                baseline = try await dependencies.updateBaseline(existing.skillID)
            } catch let problem as ManagedLocalImportProblem {
                throw problem
            } catch {
                throw managedInstallKnownProblem(for: error)
                    ?? ManagedLocalImportProblem.failed(error.localizedDescription)
            }
            let payload = baseline.domain.payload
            expectedBaseline = baseline
            skillID = payload.skill.skillID
            displayName = payload.skill.displayName
            slug = payload.skill.defaultDistributionSlug
            do {
                resolvedScope = try baseline.distributionSelection.desiredScope(for: skillID)
            } catch {
                throw ManagedLocalImportProblem.providerConflict
            }
            disposition = try remoteDisposition(
                existing: existing,
                payload: payload,
                input: providerInput,
                candidate: candidate
            )
        } else if let sourceInput {
            let prepared = try await prepareSourceInput(
                sourceInput,
                candidate: candidate,
                requestedScope: resolvedScope
            )
            skillID = prepared.skillID
            displayName = prepared.displayName
            slug = prepared.slug
            resolvedScope = prepared.scope
            disposition = prepared.disposition
            expectedBaseline = prepared.baseline
            preparedSource = prepared.source
        }
        let plan = try await dependencies.plan(
            skillID,
            resolvedScope,
            resolvedScope.requiredAdapterCodes
        )
        let preview = ManagedLocalImportPreview(
            token: ManagedLocalImportToken(),
            skillID: skillID,
            displayName: displayName,
            distributionSlug: slug,
            desiredScope: resolvedScope,
            plan: plan,
            disposition: disposition,
            allowsBlockedCreate: allowsBlockedCreate,
            source: sourceInput?.preview
        )
        states[preview.token] = .pending(Pending(
            preview: preview,
            operationID: SSOTOperationID(),
            backupID: SkillBackupID(),
            candidate: candidate,
            providerInput: providerInput,
            preparedSource: preparedSource,
            expectedBaseline: expectedBaseline,
            canonicalPlan: try plan.canonicalJSONData()
        ))
        return preview
    }

    func execute(_ token: ManagedLocalImportToken) async throws -> ManagedLocalImportResult {
        guard let state = states[token] else { throw ManagedLocalImportProblem.tokenExpired }
        switch state {
        case .completed(let result):
            return result
        case .failed(let problem):
            throw problem
        case .executing:
            throw ManagedLocalImportProblem.operationInProgress
        case .pending(let pending):
            guard pending.preview.plan.status != .blocked
                    || pending.preview.allowsBlockedCreate else {
                throw ManagedLocalImportProblem.previewBlocked
            }
            states[token] = .executing
            do {
                let result = try await perform(pending)
                states[token] = .completed(result)
                return result
            } catch let problem as ManagedLocalImportProblem {
                states[token] = .failed(problem)
                throw problem
            } catch {
                let problem = ManagedLocalImportProblem.failed(error.localizedDescription)
                states[token] = .failed(problem)
                throw problem
            }
        }
    }

    private func perform(_ pending: Pending) async throws -> ManagedLocalImportResult {
        do {
            try pending.candidate.requireSourceUnchanged()
        } catch {
            throw ManagedLocalImportProblem.sourceChanged
        }
        if let preparedSource = pending.preparedSource {
            let revision = try await preparedSource.input.refreshHead()
            guard revision == preparedSource.input.revision,
                  try await unchangedSourceAdmission(preparedSource.admission, pending: pending) else {
                throw ManagedLocalImportProblem.previewExpired
            }
        }
        let preview = pending.preview
        let confirmedPlan = try await plan(for: preview)
        guard try confirmedPlan.canonicalJSONData() == pending.canonicalPlan else {
            throw ManagedLocalImportProblem.previewExpired
        }
        switch preview.disposition {
        case .alreadyManaged:
            guard try await unchangedExistingPayload(pending) else {
                throw ManagedLocalImportProblem.providerConflict
            }
            return result(preview, status: .alreadyManaged)
        case .updateRequired:
            guard try await unchangedExistingPayload(pending) else {
                throw ManagedLocalImportProblem.providerConflict
            }
            guard let baseline = pending.expectedBaseline else {
                throw ManagedLocalImportProblem.previewExpired
            }
            if let preparedSource = pending.preparedSource {
                return try await ManagedRemoteUpdateService(
                    dependencies: dependencies
                ).execute(
                    preview: preview,
                    baseline: baseline,
                    preparedSource: preparedSource,
                    candidate: pending.candidate,
                    operationID: pending.operationID,
                    backupID: pending.backupID
                )
            }
            guard let providerInput = pending.providerInput else {
                throw ManagedLocalImportProblem.providerConflict
            }
            return try await ManagedRemoteUpdateService(
                dependencies: dependencies
            ).execute(
                preview: preview,
                baseline: baseline,
                providerInput: providerInput,
                candidate: pending.candidate,
                operationID: pending.operationID,
                backupID: pending.backupID
            )
        case .createNew:
            break
        }

        let timestamp = max(0, dependencies.nowMilliseconds())
        let skill = try ManagedSkillRecord(
            skillID: preview.skillID,
            displayName: preview.displayName,
            defaultDistributionSlug: preview.distributionSlug,
            contentFingerprint: SkillContentFingerprint(
                currentDigest: pending.candidate.snapshot.fingerprintDigest
            ),
            createdAtMilliseconds: timestamp,
            updatedAtMilliseconds: timestamp
        )
        let provenance = try pending.providerInput.map { try $0.record(skillID: preview.skillID) }
        let source = pending.preparedSource.map {
            SkillSourceRecord(
                sourceID: $0.sourceID,
                skillID: preview.skillID,
                repositoryURL: $0.input.repositoryURL,
                subpath: $0.input.subpath,
                revision: $0.input.revision,
                downloadURL: $0.input.downloadURL
            )
        }
        let aliases = pending.preparedSource.map {
            [ProviderAliasRecord(sourceID: $0.sourceID, identity: $0.input.alias)]
        } ?? []
        let payload = try SSOTSkillWritePayload(
            skill: skill,
            source: source,
            providerAliases: aliases,
            providerProvenance: provenance.map { [$0] } ?? []
        )
        let createState: CreateState
        if let preparedSource = pending.preparedSource {
            createState = await createSourceBacked(
                payload: payload,
                snapshot: pending.candidate.snapshot,
                operationID: pending.operationID,
                admission: preparedSource.admission
            )
        } else {
            createState = await create(
                payload: payload,
                snapshot: pending.candidate.snapshot,
                operationID: pending.operationID
            )
        }
        switch createState {
        case .committed:
            break
        case .failed(let problem):
            if pending.preparedSource == nil,
               let duplicate = try await duplicateResult(pending) {
                return duplicate
            }
            throw problem
        case .indeterminate:
            if pending.preparedSource == nil,
               let duplicate = try await duplicateResult(pending) {
                return duplicate
            }
            return result(preview, status: .managementIndeterminate)
        }

        if confirmedPlan.status == .blocked {
            return result(preview, status: .managedUndistributed)
        }
        let postCreatePlan: DistributionPlan
        do {
            postCreatePlan = try await plan(for: preview)
            guard try postCreatePlan.canonicalJSONData() == pending.canonicalPlan else {
                return result(preview, status: .managedDistributionIndeterminate)
            }
        } catch {
            return result(preview, status: .managedDistributionIndeterminate)
        }
        return try await distribute(preview, plan: postCreatePlan)
    }

    enum CreateState: Equatable {
        case committed
        case failed(ManagedLocalImportProblem)
        case indeterminate
    }

    private func create(
        payload: SSOTSkillWritePayload,
        snapshot: SkillContentSnapshot,
        operationID: SSOTOperationID
    ) async -> CreateState {
        do {
            let record = try await dependencies.create(payload, snapshot, operationID)
            return createState(record)
        } catch let createError {
            do {
                return createState(try await dependencies.operationReadback(operationID))
            } catch SSOTJournalStoreError.operationNotFound {
                do {
                    guard let stored = try await dependencies.domainReadback(
                        payload.skill.skillID
                    ) else {
                        return .failed(problem(for: createError))
                    }
                    guard try canonicalPayload(stored) == canonicalPayload(payload) else {
                        return .failed(.needsRepair)
                    }
                    return .committed
                } catch {
                    return .indeterminate
                }
            } catch {
                return .indeterminate
            }
        }
    }

    func createState(_ record: SSOTJournalRecord) -> CreateState {
        if record.state.outcome == .needsRepair || record.state.cleanupState == .needsRepair {
            return .failed(.needsRepair)
        }
        guard record.state.phase == .completed else { return .indeterminate }
        switch record.state.outcome {
        case .applied:
            return .committed
        case .rolledBack:
            return .failed(.createRolledBack)
        case .needsRepair:
            return .failed(.needsRepair)
        case .pending:
            return .indeterminate
        }
    }

    func problem(for error: Error) -> ManagedLocalImportProblem {
        managedInstallKnownProblem(for: error) ?? .failed(error.localizedDescription)
    }

    private func distribute(
        _ preview: ManagedLocalImportPreview,
        plan: DistributionPlan
    ) async throws -> ManagedLocalImportResult {
        switch plan.status {
        case .blocked:
            return result(preview, status: .managedUndistributed)
        case .noOp:
            return result(preview, status: .noDistributionChanges)
        case .executable:
            do {
                let operation = try await dependencies.apply(preview.skillID, plan)
                guard operation.phase == .completed, operation.outcome == .applied else {
                    return result(preview, status: .managedDistributionIndeterminate)
                }
                return result(preview, status: .distributed)
            } catch {
                return await distributionFailureResult(preview)
            }
        }
    }

    private func distributionFailureResult(
        _ preview: ManagedLocalImportPreview
    ) async -> ManagedLocalImportResult {
        guard let reconcile = try? await dependencies.reconcile(preview.skillID) else {
            return result(preview, status: .managedDistributionIndeterminate)
        }
        switch reconcile.status {
        case .needsRepair, .operationInProgress, .drifted:
            return result(preview, status: .managedDistributionIndeterminate)
        case .inSync:
            guard let currentPlan = try? await plan(for: preview) else {
                return result(preview, status: .managedDistributionIndeterminate)
            }
            return result(
                preview,
                status: currentPlan.status == .noOp ? .distributed : .managedUndistributed
            )
        }
    }

    private func plan(for preview: ManagedLocalImportPreview) async throws -> DistributionPlan {
        try await dependencies.plan(
            preview.skillID,
            preview.desiredScope,
            preview.desiredScope.requiredAdapterCodes
        )
    }

    private func duplicateResult(
        _ pending: Pending
    ) async throws -> ManagedLocalImportResult? {
        guard let input = pending.providerInput,
              let existing = try await dependencies.provenanceReadback(input.identity)
        else {
            return nil
        }
        guard let payload = try await dependencies.domainReadback(existing.skillID) else {
            throw ManagedLocalImportProblem.providerConflict
        }
        let disposition = try remoteDisposition(
            existing: existing,
            payload: payload,
            input: input,
            candidate: pending.candidate
        )
        let status: ManagedLocalImportResultStatus =
            disposition == .alreadyManaged ? .alreadyManaged : .updateRequired
        return ManagedLocalImportResult(
            skillID: existing.skillID,
            displayName: payload.skill.displayName.value,
            status: status
        )
    }

    func canonicalPayload(_ payload: SSOTSkillWritePayload) throws -> Data {
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
