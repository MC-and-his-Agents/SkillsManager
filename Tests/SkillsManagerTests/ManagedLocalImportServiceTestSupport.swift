import Darwin
import Foundation
import Testing

@testable import SkillsManager

actor ManagedLocalImportProbe {
    private let planStatuses: [DistributionPlanStatus]
    private let createDelay: Duration?
    private let createThrows: Bool
    private let readbackState: SSOTJournalState
    private let applyThrows: Bool
    private let reconcileStatus: DistributionReconcileStatus
    private var planIndex = 0
    private var lastPayload: SSOTSkillWritePayload?
    private var lastOperationID: SSOTOperationID?
    private(set) var requestedAdapterCodes: [Set<String>] = []
    private(set) var createCount = 0
    private(set) var applyCount = 0

    var createdPayload: SSOTSkillWritePayload? { lastPayload }

    init(
        planStatuses: [DistributionPlanStatus] = [.executable],
        createDelay: Duration? = nil,
        createThrows: Bool = false,
        readbackState: SSOTJournalState = .init(
            phase: .completed,
            outcome: .applied,
            cleanupState: .notApplicable
        ),
        applyThrows: Bool = false,
        reconcileStatus: DistributionReconcileStatus = .inSync
    ) {
        self.planStatuses = planStatuses
        self.createDelay = createDelay
        self.createThrows = createThrows
        self.readbackState = readbackState
        self.applyThrows = applyThrows
        self.reconcileStatus = reconcileStatus
    }

    nonisolated func dependencies() -> ManagedLocalImportDependencies {
        ManagedLocalImportDependencies(
            plan: { skillID, scope, codes in
                try await self.plan(skillID: skillID, scope: scope, codes: codes)
            },
            create: { payload, _, operationID in
                try await self.create(payload: payload, operationID: operationID)
            },
            createReadback: { try await self.readback(operationID: $0) },
            apply: { skillID, _ in try await self.apply(skillID: skillID) },
            reconcile: { _ in await self.reconcile() },
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
        if createThrows {
            throw ManagedLocalImportProblem.failed("injected create failure")
        }
        return try importJournalRecord(
            payload: payload,
            operationID: operationID,
            state: readbackState
        )
    }

    private func readback(operationID: SSOTOperationID) throws -> SSOTJournalRecord {
        guard operationID == lastOperationID, let lastPayload else {
            throw SSOTJournalStoreError.operationNotFound
        }
        return try importJournalRecord(
            payload: lastPayload,
            operationID: operationID,
            state: readbackState
        )
    }

    private func apply(skillID: SkillID) throws -> DistributionOperationRecord {
        applyCount += 1
        if applyThrows {
            throw ManagedLocalImportProblem.failed("injected distribution failure")
        }
        return distributionOperation(skillID: skillID)
    }

    private func reconcile() -> DistributionReconcileResult {
        DistributionReconcileResult(status: reconcileStatus, observations: [:])
    }
}

private func importJournalRecord(
    payload: SSOTSkillWritePayload,
    operationID: SSOTOperationID,
    state: SSOTJournalState
) throws -> SSOTJournalRecord {
    try SSOTJournalRecord(
        operationID: operationID,
        operationType: .create,
        skillID: payload.skill.skillID,
        state: state,
        stagingLocator: ".skillsmanager-tmp-\(operationID.uuid.uuidString.lowercased())",
        finalLocator: payload.skill.skillID.directoryName,
        recoveryLocator: nil,
        oldFingerprint: nil,
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
