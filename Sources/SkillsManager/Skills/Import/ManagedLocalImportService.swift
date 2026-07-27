import Foundation

nonisolated enum ManagedLocalImportScope: Equatable, Sendable {
    case global
    case agents(Set<SkillPlatform>)

    func desiredScope(slug: DefaultDistributionSlug) throws -> DistributionDesiredScope {
        switch self {
        case .global:
            return .global(slug)
        case .agents(let agents):
            guard !agents.isEmpty else { throw ManagedLocalImportProblem.emptyAgentSelection }
            return .agents(agents, slug)
        }
    }
}

nonisolated struct ManagedLocalImportToken: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

nonisolated struct ManagedLocalImportPreview: Identifiable, Sendable {
    let token: ManagedLocalImportToken
    let skillID: SkillID
    let displayName: SkillDisplayName
    let distributionSlug: DefaultDistributionSlug
    let desiredScope: DistributionDesiredScope
    let plan: DistributionPlan

    var id: ManagedLocalImportToken { token }
}

nonisolated enum ManagedLocalImportResultStatus: Equatable, Sendable {
    case distributed
    case noDistributionChanges
    case managedUndistributed
    case managedDistributionIndeterminate
    case managementIndeterminate
}

nonisolated struct ManagedLocalImportResult: Equatable, Sendable {
    let skillID: SkillID
    let displayName: String
    let status: ManagedLocalImportResultStatus
}

nonisolated enum ManagedLocalImportProblem: LocalizedError, Equatable, Sendable {
    case emptyAgentSelection
    case invalidCandidate
    case operationInProgress
    case previewBlocked
    case previewExpired
    case sourceChanged
    case tokenExpired
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyAgentSelection:
            "Select at least one Agent."
        case .invalidCandidate:
            "The selected Skill is no longer valid."
        case .operationInProgress:
            "This import is already in progress."
        case .previewBlocked:
            "Resolve the distribution conflicts before importing."
        case .previewExpired:
            "The import preview changed. Review it again before importing."
        case .sourceChanged:
            "The selected Skill changed after validation. Choose it again."
        case .tokenExpired:
            "The import preview expired. Prepare a new preview."
        case .failed(let detail):
            "Import failed: \(detail)"
        }
    }
}

nonisolated struct ManagedLocalImportDependencies: Sendable {
    let plan: @Sendable (
        SkillID,
        DistributionDesiredScope,
        Set<String>
    ) async throws -> DistributionPlan
    let create: @Sendable (
        SSOTSkillWritePayload,
        SkillContentSnapshot,
        SSOTOperationID
    ) async throws -> SSOTJournalRecord
    let createReadback: @Sendable (SSOTOperationID) async throws -> SSOTJournalRecord
    let apply: @Sendable (SkillID, DistributionPlan) async throws -> DistributionOperationRecord
    let reconcile: @Sendable (SkillID) async throws -> DistributionReconcileResult
    let nowMilliseconds: @Sendable () -> Int64

    static func live(writer: JournaledSSOTWriter) -> Self {
        let distribution = SkillDistributionDependencies.live(writer: writer)
        return Self(
            plan: distribution.plan,
            create: { payload, snapshot, operationID in
                try await writer.create(
                    payload: payload,
                    sourceSnapshot: snapshot,
                    operationID: operationID
                )
            },
            createReadback: { try await writer.ssotOperationReadback($0) },
            apply: distribution.apply,
            reconcile: distribution.reconcile,
            nowMilliseconds: { max(0, Int64(Date().timeIntervalSince1970 * 1_000)) }
        )
    }
}

actor ManagedLocalImportService {
    private struct Pending: Sendable {
        let preview: ManagedLocalImportPreview
        let operationID: SSOTOperationID
        let candidate: SkillImportWorker.ImportCandidatePayload
        let canonicalPlan: Data
    }

    private enum State: Sendable {
        case pending(Pending)
        case executing
        case completed(ManagedLocalImportResult)
        case failed(ManagedLocalImportProblem)
    }

    private let dependencies: ManagedLocalImportDependencies
    private var states: [ManagedLocalImportToken: State] = [:]

    init(dependencies: ManagedLocalImportDependencies) {
        self.dependencies = dependencies
    }

    func prepare(
        candidate: SkillImportWorker.ImportCandidatePayload,
        displayName rawDisplayName: String,
        scope: ManagedLocalImportScope
    ) async throws -> ManagedLocalImportPreview {
        guard candidate.snapshot.fingerprint == candidate.fingerprint else {
            throw ManagedLocalImportProblem.invalidCandidate
        }
        let displayName = try SkillDisplayName(rawDisplayName)
        let slug = try DefaultDistributionSlug(candidateFrom: displayName)
        let desiredScope = try scope.desiredScope(slug: slug)
        let skillID = SkillID()
        let plan = try await dependencies.plan(
            skillID,
            desiredScope,
            desiredScope.requiredAdapterCodes
        )
        let preview = ManagedLocalImportPreview(
            token: ManagedLocalImportToken(),
            skillID: skillID,
            displayName: displayName,
            distributionSlug: slug,
            desiredScope: desiredScope,
            plan: plan
        )
        states[preview.token] = .pending(Pending(
            preview: preview,
            operationID: SSOTOperationID(),
            candidate: candidate,
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
            guard pending.preview.plan.status != .blocked else {
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
        let payload = try SSOTSkillWritePayload(skill: skill)
        let createState = await create(
            payload: payload,
            snapshot: pending.candidate.snapshot,
            operationID: pending.operationID
        )
        guard createState == .committed else {
            return result(preview, status: .managementIndeterminate)
        }

        let postCreatePlan = try await plan(for: preview)
        guard try postCreatePlan.canonicalJSONData() == pending.canonicalPlan else {
            return result(preview, status: .managedUndistributed)
        }
        return try await distribute(preview, plan: postCreatePlan)
    }

    private enum CreateState: Equatable {
        case committed
        case indeterminate
    }

    private func create(
        payload: SSOTSkillWritePayload,
        snapshot: SkillContentSnapshot,
        operationID: SSOTOperationID
    ) async -> CreateState {
        do {
            let record = try await dependencies.create(payload, snapshot, operationID)
            return isCommitted(record) ? .committed : .indeterminate
        } catch {
            guard let record = try? await dependencies.createReadback(operationID) else {
                return .indeterminate
            }
            return isCommitted(record) ? .committed : .indeterminate
        }
    }

    private func isCommitted(_ record: SSOTJournalRecord) -> Bool {
        record.state.phase == .completed && record.state.outcome == .applied
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
