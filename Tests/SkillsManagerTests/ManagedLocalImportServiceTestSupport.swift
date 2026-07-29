import Darwin
import Foundation
import Testing

@testable import SkillsManager

actor ManagedLocalImportProbe {
    enum CreateFailure {
        case none
        case generic
        case permission
    }

    enum ReplaceFailure: Equatable {
        case none
        case beforeJournal
        case afterCommit
    }

    private let planStatuses: [DistributionPlanStatus]
    private let createDelay: Duration?
    private let createFailure: CreateFailure
    private let replaceDelay: Duration?
    private let replaceFailure: ReplaceFailure
    private let readbackState: SSOTJournalState
    private let operationReadbackFound: Bool
    private let skillExistsOnReadback: Bool
    private let existingPayload: SSOTSkillWritePayload?
    private let existingProvenance: ProviderProvenanceRecord?
    private let baselineNeedsRepair: Bool
    private let provenanceAppearsAfterCreate: Bool
    private let applyThrows: Bool
    private let reconcileStatus: DistributionReconcileStatus
    private let reconcileThrows: Bool
    private let existingBindings: [DistributionBinding]
    private var planIndex = 0
    private var lastPayload: SSOTSkillWritePayload?
    private var lastOperationID: SSOTOperationID?
    private var replaceCommitted = false
    private(set) var requestedAdapterCodes: [Set<String>] = []
    private(set) var createCount = 0
    private(set) var replaceCount = 0
    private(set) var applyCount = 0
    private(set) var reconcileCount = 0

    var createdPayload: SSOTSkillWritePayload? { lastPayload }

    init(
        planStatuses: [DistributionPlanStatus] = [.executable],
        createDelay: Duration? = nil,
        createFailure: CreateFailure = .none,
        replaceDelay: Duration? = nil,
        replaceFailure: ReplaceFailure = .none,
        readbackState: SSOTJournalState = .init(
            phase: .completed,
            outcome: .applied,
            cleanupState: .notApplicable
        ),
        operationReadbackFound: Bool = true,
        skillExistsOnReadback: Bool = false,
        existingPayload: SSOTSkillWritePayload? = nil,
        existingProvenance: ProviderProvenanceRecord? = nil,
        baselineNeedsRepair: Bool = false,
        provenanceAppearsAfterCreate: Bool = false,
        applyThrows: Bool = false,
        reconcileStatus: DistributionReconcileStatus = .inSync,
        reconcileThrows: Bool = false,
        existingBindings: [DistributionBinding] = []
    ) {
        self.planStatuses = planStatuses
        self.createDelay = createDelay
        self.createFailure = createFailure
        self.replaceDelay = replaceDelay
        self.replaceFailure = replaceFailure
        self.readbackState = readbackState
        self.operationReadbackFound = operationReadbackFound
        self.skillExistsOnReadback = skillExistsOnReadback
        self.existingPayload = existingPayload
        self.existingProvenance = existingProvenance
        self.baselineNeedsRepair = baselineNeedsRepair
        self.provenanceAppearsAfterCreate = provenanceAppearsAfterCreate
        self.applyThrows = applyThrows
        self.reconcileStatus = reconcileStatus
        self.reconcileThrows = reconcileThrows
        self.existingBindings = existingBindings
    }

    nonisolated func dependencies() -> ManagedInstallDependencies {
        ManagedInstallDependencies(
            plan: { skillID, scope, codes in
                try await self.plan(skillID: skillID, scope: scope, codes: codes)
            },
            create: { payload, _, operationID in
                try await self.create(payload: payload, operationID: operationID)
            },
            operationReadback: { try await self.readback(operationID: $0) },
            domainReadback: { try await self.domainReadback(skillID: $0) },
            provenanceReadback: { identity in
                await self.provenanceReadback(identity: identity)
            },
            sourceReadback: { _, _ in nil },
            aliasOwnerReadback: { _ in nil },
            updateBaseline: { try await self.updateBaseline(skillID: $0) },
            replaceWithBackup: { baseline, payload, _, operationID, backupID in
                try await self.replace(
                    baseline: baseline,
                    payload: payload,
                    operationID: operationID,
                    backupID: backupID
                )
            },
            createSourceBacked: { payload, _, operationID, _ in
                try await self.create(payload: payload, operationID: operationID)
            },
            replaceSourceBackedWithBackup: {
                baseline, payload, _, operationID, backupID, _ in
                try await self.replace(
                    baseline: baseline,
                    payload: payload,
                    operationID: operationID,
                    backupID: backupID
                )
            },
            apply: { skillID, _ in try await self.apply(skillID: skillID) },
            reconcile: { _ in try await self.reconcile() },
            nowMilliseconds: { 100 }
        )
    }

    private func plan(
        skillID: SkillID,
        scope: DistributionDesiredScope,
        codes: Set<String>
    ) throws -> DistributionPlan {
        requestedAdapterCodes.append(codes)
        let status = planStatuses[min(planIndex, planStatuses.count - 1)]
        planIndex += 1
        let replacement = intents(skillID: skillID, scope: scope)
        if status == .blocked {
            let slug = try #require(scope.distributionSlug)
            return distributionPlan(
                status: .blocked,
                conflicts: [
                    DistributionPlanConflict(
                        reason: .slugOccupied,
                        targetScopeKey: "global",
                        targetRank: 0,
                        slugKey: slug.collisionKey,
                        canonicalLocator: "~/.agents/skills/\(slug.value)"
                    ),
                ]
            )
        }
        return distributionPlan(
            status: status,
            replacement: status == .noOp ? [] : replacement,
            configurationChanged: status == .executable,
            expectedOldConfigured: false
        )
    }

    private func intents(
        skillID: SkillID,
        scope: DistributionDesiredScope
    ) -> [DistributionBindingIntent] {
        guard let slug = scope.distributionSlug else { return [] }
        switch scope {
        case .disabled:
            return []
        case .global:
            return [DistributionBindingIntent(
                skillID: skillID,
                scope: .global,
                distributionSlug: slug
            )]
        case .agents(let agents, _):
            return agents.map {
                DistributionBindingIntent(
                    skillID: skillID,
                    scope: .agent($0),
                    distributionSlug: slug
                )
            }
        }
    }

    private func create(
        payload: SSOTSkillWritePayload,
        operationID: SSOTOperationID
    ) async throws -> SSOTJournalRecord {
        createCount += 1
        lastPayload = payload
        lastOperationID = operationID
        if let createDelay {
            try await Task.sleep(for: createDelay)
        }
        switch createFailure {
        case .none:
            break
        case .generic:
            throw ManagedLocalImportProblem.failed("injected create failure")
        case .permission:
            throw ManagedPathError.posix(operation: "create", code: EACCES)
        }
        return try importJournalRecord(
            payload: payload,
            operationID: operationID,
            state: readbackState
        )
    }

    private func readback(operationID: SSOTOperationID) throws -> SSOTJournalRecord {
        guard operationReadbackFound else {
            throw SSOTJournalStoreError.operationNotFound
        }
        guard operationID == lastOperationID, let lastPayload else {
            throw SSOTJournalStoreError.operationNotFound
        }
        return try importJournalRecord(
            payload: lastPayload,
            operationID: operationID,
            state: readbackState
        )
    }

    private func domainReadback(skillID: SkillID) throws -> SSOTSkillWritePayload? {
        if replaceCommitted, lastPayload?.skill.skillID == skillID {
            return lastPayload
        }
        if existingPayload?.skill.skillID == skillID {
            return existingPayload
        }
        guard skillExistsOnReadback,
              let payload = lastPayload,
              payload.skill.skillID == skillID else {
            return nil
        }
        return payload
    }

    private func provenanceReadback(
        identity: ProviderAliasIdentity
    ) -> ProviderProvenanceRecord? {
        guard !provenanceAppearsAfterCreate || createCount > 0 else { return nil }
        guard existingProvenance?.identity == identity else { return nil }
        return existingProvenance
    }

    private func updateBaseline(skillID: SkillID) throws -> ManagedSkillUpdateBaseline {
        if baselineNeedsRepair {
            throw ManagedSkillUpdateBackupError.backupNeedsRepair
        }
        guard let payload = existingPayload, payload.skill.skillID == skillID else {
            throw ManagedLocalImportProblem.providerConflict
        }
        return ManagedSkillUpdateBaseline(
            domain: StoredSkillDomainSnapshot(payload: payload, revision: 1),
            finalIdentity: importIdentity(inode: 10),
            distributionSelection: DistributionSelectionReadback(
                bindings: existingBindings,
                isExplicitlyConfigured: !existingBindings.isEmpty
            )
        )
    }

    private func replace(
        baseline: ManagedSkillUpdateBaseline,
        payload: SSOTSkillWritePayload,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) async throws -> ManagedSkillUpdateWriteResult {
        replaceCount += 1
        lastOperationID = operationID
        if let replaceDelay {
            try await Task.sleep(for: replaceDelay)
        }
        if replaceFailure == .beforeJournal {
            throw ManagedLocalImportProblem.updateFailed("injected backup failure")
        }
        lastPayload = payload
        replaceCommitted = replaceFailure == .afterCommit
            || (readbackState.phase == .completed && readbackState.outcome == .applied)
        if replaceFailure == .afterCommit {
            throw ManagedLocalImportProblem.updateFailed("injected readback failure")
        }
        let backup = try SkillBackupRecord(
            backupID: backupID,
            originalSkillID: payload.skill.skillID,
            state: .available,
            locator: "\(payload.skill.skillID.directoryName)/100-\(backupID.uuid.uuidString.lowercased())",
            directoryIdentity: importIdentity(inode: 20),
            manifestDigest: Data(repeating: 1, count: 32),
            contentFingerprint: baseline.domain.payload.skill.contentFingerprint,
            createdAtMilliseconds: 100,
            updatedAtMilliseconds: 100
        )
        return ManagedSkillUpdateWriteResult(
            backup: backup,
            replacement: try importJournalRecord(
                payload: payload,
                operationID: operationID,
                state: readbackState,
                operationType: .replace,
                oldFingerprint: baseline.domain.payload.skill.contentFingerprint
            )
        )
    }

    private func apply(skillID: SkillID) throws -> DistributionOperationRecord {
        applyCount += 1
        if applyThrows {
            throw ManagedLocalImportProblem.failed("injected distribution failure")
        }
        return distributionOperation(skillID: skillID)
    }

    private func reconcile() throws -> DistributionReconcileResult {
        reconcileCount += 1
        if reconcileThrows {
            throw ManagedLocalImportProblem.failed("injected reconcile failure")
        }
        return DistributionReconcileResult(status: reconcileStatus, observations: [:])
    }

    func waitUntilReplaceStarts() async -> Bool {
        for _ in 0..<10_000 {
            if replaceCount > 0 { return true }
            await Task.yield()
        }
        return false
    }
}

func writerDependencies(
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
        operationReadback: { try await writer.ssotOperationReadback($0) },
        domainReadback: { try await writer.storedDomainReadback($0)?.payload },
        provenanceReadback: { try await writer.providerProvenance($0) },
        sourceReadback: {
            try await writer.sourceDomainReadback(repositoryURL: $0, subpath: $1)
        },
        aliasOwnerReadback: { try await writer.providerAliasOwnerReadback($0) },
        updateBaseline: { try await writer.managedSkillUpdateBaseline($0) },
        replaceWithBackup: { baseline, payload, snapshot, operationID, backupID in
            try await writer.replaceManagedSkillWithBackup(
                expected: baseline,
                replacementPayload: payload,
                sourceSnapshot: snapshot,
                operationID: operationID,
                backupID: backupID
            )
        },
        createSourceBacked: { payload, snapshot, operationID, admission in
            try await writer.createSourceBacked(
                payload: payload,
                sourceSnapshot: snapshot,
                operationID: operationID,
                admission: admission
            )
        },
        replaceSourceBackedWithBackup: {
            baseline, payload, snapshot, operationID, backupID, admission in
            try await writer.replaceSourceBackedWithBackup(
                expected: baseline,
                replacementPayload: payload,
                sourceSnapshot: snapshot,
                operationID: operationID,
                backupID: backupID,
                admission: admission
            )
        },
        apply: probe.apply,
        reconcile: probe.reconcile,
        nowMilliseconds: probe.nowMilliseconds
    )
}

private func importJournalRecord(
    payload: SSOTSkillWritePayload,
    operationID: SSOTOperationID,
    state: SSOTJournalState,
    operationType: SSOTOperationType = .create,
    oldFingerprint: SkillContentFingerprint? = nil
) throws -> SSOTJournalRecord {
    try SSOTJournalRecord(
        operationID: operationID,
        operationType: operationType,
        skillID: payload.skill.skillID,
        state: state,
        stagingLocator: ".skillsmanager-tmp-\(operationID.uuid.uuidString.lowercased())",
        finalLocator: payload.skill.skillID.directoryName,
        recoveryLocator: operationType == .replace
            ? ".skillsmanager-recovery-\(operationID.uuid.uuidString.lowercased())"
            : nil,
        oldFingerprint: oldFingerprint,
        newFingerprint: payload.skill.contentFingerprint,
        payload: payload,
        expectedStagedIdentity: importIdentity(inode: 1),
        expectedOldIdentity: nil,
        expectedNewIdentity: importIdentity(inode: 2),
        expectedDatabaseRevision: 0,
        expectedRootIdentity: importIdentity(inode: 3),
        createdAtMilliseconds: 100,
        updatedAtMilliseconds: 100
    )
}

private func importIdentity(inode: UInt64) -> ManagedItemIdentity {
    ManagedItemIdentity(persistedComponents: .init(
        device: 1,
        inode: inode,
        fileType: UInt32(S_IFDIR),
        generation: 0
    ))
}

actor ManagedLocalImportFinalizationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting = false

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            waiting = true
        }
    }

    func waitUntilWaiting() async -> Bool {
        for _ in 0..<10_000 {
            if waiting { return true }
            await Task.yield()
        }
        return false
    }

    func open() {
        continuation?.resume()
        continuation = nil
        waiting = false
    }
}
