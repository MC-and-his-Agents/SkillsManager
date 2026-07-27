import Darwin
import Foundation

actor ManagedInstallService {
    private struct Pending: Sendable {
        let preview: ManagedLocalImportPreview
        let operationID: SSOTOperationID
        let candidate: SkillImportWorker.ImportCandidatePayload
        let providerInput: ManagedInstallProviderInput?
        let expectedPayload: SSOTSkillWritePayload?
        let canonicalPlan: Data
    }

    private enum State: Sendable {
        case pending(Pending)
        case executing
        case completed(ManagedLocalImportResult)
        case failed(ManagedLocalImportProblem)
    }

    private let dependencies: ManagedInstallDependencies
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

    private func prepare(
        candidate: SkillImportWorker.ImportCandidatePayload,
        displayName rawDisplayName: String,
        distributionSlug: DefaultDistributionSlug?,
        scope: ManagedLocalImportScope,
        providerInput: ManagedInstallProviderInput?,
        allowsBlockedCreate: Bool
    ) async throws -> ManagedLocalImportPreview {
        guard candidate.snapshot.fingerprint == candidate.fingerprint else {
            throw ManagedLocalImportProblem.invalidCandidate
        }
        var displayName = try SkillDisplayName(rawDisplayName)
        var slug = try distributionSlug ?? DefaultDistributionSlug(candidateFrom: displayName)
        var skillID = SkillID()
        var disposition: ManagedLocalImportPreview.Disposition = .createNew
        var expectedPayload: SSOTSkillWritePayload?
        if let providerInput,
           let existing = try await dependencies.provenanceReadback(providerInput.identity) {
            guard let payload = try await dependencies.domainReadback(existing.skillID) else {
                throw ManagedLocalImportProblem.providerConflict
            }
            expectedPayload = payload
            skillID = payload.skill.skillID
            displayName = payload.skill.displayName
            slug = payload.skill.defaultDistributionSlug
            disposition = try remoteDisposition(
                existing: existing,
                payload: payload,
                input: providerInput,
                candidate: candidate
            )
        }
        let resolvedScope = try scope.desiredScope(slug: slug)
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
            allowsBlockedCreate: allowsBlockedCreate
        )
        states[preview.token] = .pending(Pending(
            preview: preview,
            operationID: SSOTOperationID(),
            candidate: candidate,
            providerInput: providerInput,
            expectedPayload: expectedPayload,
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
        let preview = pending.preview
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
            return result(preview, status: .updateRequired)
        case .createNew:
            break
        }
        let currentPlan = try await plan(for: preview)
        guard try currentPlan.canonicalJSONData() == pending.canonicalPlan else {
            throw ManagedLocalImportProblem.previewExpired
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
        let payload = try SSOTSkillWritePayload(
            skill: skill,
            providerProvenance: provenance.map { [$0] } ?? []
        )
        let createState = await create(
            payload: payload,
            snapshot: pending.candidate.snapshot,
            operationID: pending.operationID
        )
        switch createState {
        case .committed:
            break
        case .failed(let problem):
            if let duplicate = try await duplicateResult(pending) {
                return duplicate
            }
            throw problem
        case .indeterminate:
            if let duplicate = try await duplicateResult(pending) {
                return duplicate
            }
            return result(preview, status: .managementIndeterminate)
        }

        if currentPlan.status == .blocked {
            return result(preview, status: .managedUndistributed)
        }
        let postCreatePlan = try await plan(for: preview)
        guard try postCreatePlan.canonicalJSONData() == pending.canonicalPlan else {
            return result(preview, status: .managedUndistributed)
        }
        return try await distribute(preview, plan: postCreatePlan)
    }

    private enum CreateState: Equatable {
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
                return createState(try await dependencies.createReadback(operationID))
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

    private func createState(_ record: SSOTJournalRecord) -> CreateState {
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

    private func problem(for error: Error) -> ManagedLocalImportProblem {
        if error is CancellationError {
            return .failed("Import was cancelled.")
        }
        if let error = error as? JournaledSSOTWriterError {
            switch error {
            case .operationNeedsRepair:
                return .needsRepair
            case .operationRolledBack:
                return .createRolledBack
            case .invalidInput, .recoveryDidNotConverge:
                return .failed(error.localizedDescription)
            }
        }
        if let error = error as? SSOTWriterOwnershipError {
            switch error {
            case .busy:
                return .operationInProgress
            case .posix(_, let code) where code == EACCES || code == EPERM:
                return .permissionDenied
            default:
                return .failed(error.localizedDescription)
            }
        }
        if let error = error as? SkillContentSnapshotError {
            if case .fileSystemFailure(_, let code) = error,
               code == EACCES || code == EPERM {
                return .permissionDenied
            }
            return .sourceChanged
        }
        if let error = error as? ManagedPathError {
            if case .posix(_, let code) = error,
               code == EACCES || code == EPERM {
                return .permissionDenied
            }
            return .failed(error.localizedDescription)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return .permissionDenied
        }
        return .failed(error.localizedDescription)
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

    private func unchangedExistingPayload(_ pending: Pending) async throws -> Bool {
        guard let expectedPayload = pending.expectedPayload,
              let current = try await dependencies.domainReadback(
                pending.preview.skillID
              ) else {
            return false
        }
        return try canonicalPayload(current) == canonicalPayload(expectedPayload)
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

    private func remoteDisposition(
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
