import Foundation
import Testing

@testable import SkillsManager

@Suite("Historical Skill migration recovery", .serialized)
struct HistoricalSkillMigrationRecoveryTests {
    enum CommittedRecoveryPoint: CaseIterable, Sendable {
        case databaseCommitted
        case cleaning
    }

    @Test("a clean rollback retries with one existing backup and a new operation")
    func cleanRollbackRetriesWithoutDuplicateBackup() async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Retry")
        let interruption = HistoricalForwardInterruption()
        let first = try await fixture.prepareExecutorMigration(
            hooks: .init(onCheckpoint: interruption.reach)
        )
        #expect(throws: HistoricalForwardInterruption.Failure.self) {
            _ = try first.executor.apply(
                skillID: first.skillID,
                plan: first.plan,
                expectedOldBindings: [],
                approvedCopySource: first.ssotEvidence,
                approvedHistoricalMigration: first.approval,
                operationID: first.operationID,
                nowMilliseconds: 42
            )
        }
        #expect(try first.operationStore.load(first.operationID).outcome == .rolledBack)
        let prepared = try await fixture.prepare()
        #expect(prepared.observation.status == .managed)
        let service = fixture.service()
        let preview = try await service.prepare(
            audit: prepared.audit,
            observation: prepared.observation,
            importAction: nil
        )
        #expect(preview.operationID != first.operationID)

        let result = try await service.confirm(preview.token)

        #expect(result.backup.backupID == first.approval.backup.backupID)
        #expect(result.distribution.operationID == preview.operationID)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_operations") == 2)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 1)
        #expect(try fixture.isSourceSymlink())
    }

    @Test(
        "committed historical migration resumes cleanup after restart",
        arguments: CommittedRecoveryPoint.allCases
    )
    func committedMigrationRecovers(_ point: CommittedRecoveryPoint) async throws {
        let fixture = try await HistoricalMigrationFixture(content: "# Recover")
        let interruption = HistoricalCommittedInterruption(point: point)
        let prepared = try await fixture.prepareExecutorMigration(
            hooks: .init(onCheckpoint: interruption.filesystem),
            executorHooks: .init(afterDatabaseCommit: interruption.databaseCommitted)
        )
        #expect(throws: HistoricalCommittedInterruption.Failure.self) {
            _ = try prepared.executor.apply(
                skillID: prepared.skillID,
                plan: prepared.plan,
                expectedOldBindings: [],
                approvedCopySource: prepared.ssotEvidence,
                approvedHistoricalMigration: prepared.approval,
                operationID: prepared.operationID,
                nowMilliseconds: 42
            )
        }
        let interrupted = try prepared.operationStore.load(prepared.operationID)
        #expect(interrupted.phase == (
            point == .databaseCommitted ? .databaseCommitted : .cleaning
        ))

        let recovery = try await fixture.distributionExecutor()
        try recovery.executor.recoverAll()

        let completed = try recovery.operationStore.load(prepared.operationID)
        #expect(completed.phase == .completed)
        #expect(completed.outcome == .applied)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 1)
        #expect(try fixture.isSourceSymlink())
    }

    @Test("reopen recovery removes the exact origin after source cleanup")
    func committedCleanupRemovesOriginAfterReopen() async throws {
        let sourceScope = SkillDiscoveryScope.agent(
            adapterCode: SkillPlatform.codex.storageKey,
            pathVariant: SkillPlatform.codex.dedicatedDistributionRelativePath
        )
        let interruption = HistoricalCommittedInterruption(point: .cleaning)
        let fixture = try await HistoricalMigrationFixture(
            content: "# Origin cleanup",
            sourceScope: sourceScope
        )
        let prepared = try await fixture.prepareExecutorMigration(
            hooks: .init(onCheckpoint: interruption.filesystem),
            executorHooks: .init(afterDatabaseCommit: interruption.databaseCommitted),
            existingBinding: true
        )
        #expect(try fixture.workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
        #expect(throws: HistoricalCommittedInterruption.Failure.self) {
            _ = try prepared.executor.apply(
                skillID: prepared.skillID,
                plan: prepared.plan,
                expectedOldBindings: try prepared.executor.bindingStore.load(
                    skillID: prepared.skillID
                ),
                approvedCopySource: prepared.ssotEvidence,
                approvedHistoricalMigration: prepared.approval,
                operationID: prepared.operationID,
                nowMilliseconds: 42
            )
        }
        #expect(try prepared.operationStore.load(prepared.operationID).phase == .cleaning)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)

        let reopened = try await fixture.distributionExecutor()
        try reopened.executor.recoverAll()
        try reopened.executor.recoverAll()

        let completed = try reopened.operationStore.load(prepared.operationID)
        #expect(completed.phase == .completed)
        #expect(completed.outcome == .applied)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM local_skill_origins") == 0)
    }

    @Test("origin cleanup conflict becomes needs repair without deleting provenance")
    func cleanupConflictNeedsRepairAndPreservesOrigin() async throws {
        let sourceScope = SkillDiscoveryScope.agent(
            adapterCode: SkillPlatform.codex.storageKey,
            pathVariant: SkillPlatform.codex.dedicatedDistributionRelativePath
        )
        let interruption = HistoricalCommittedInterruption(point: .databaseCommitted)
        let fixture = try await HistoricalMigrationFixture(
            content: "# Origin conflict",
            sourceScope: sourceScope
        )
        let prepared = try await fixture.prepareExecutorMigration(
            executorHooks: .init(afterDatabaseCommit: interruption.databaseCommitted),
            existingBinding: true
        )
        #expect(throws: HistoricalCommittedInterruption.Failure.self) {
            _ = try prepared.executor.apply(
                skillID: prepared.skillID,
                plan: prepared.plan,
                expectedOldBindings: try prepared.executor.bindingStore.load(
                    skillID: prepared.skillID
                ),
                approvedCopySource: prepared.ssotEvidence,
                approvedHistoricalMigration: prepared.approval,
                operationID: prepared.operationID,
                nowMilliseconds: 42
            )
        }
        try fixture.workspace.execute(
            "UPDATE local_skill_origins SET confirmed_at_ms = confirmed_at_ms + 1"
        )

        let reopened = try await fixture.distributionExecutor()
        try reopened.executor.recoverAll()

        #expect(try reopened.operationStore.repairRequiredOperations().count == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM local_skill_origins") == 1)
    }

    @Test("validator binds historical approval evidence and preserves old replace journals")
    func historicalApprovalValidatorRejectsForgedEvidence() async throws {
        let legacyFixture = try await HistoricalMigrationFixture(content: "# Legacy")
        let legacy = try await legacyFixture.prepareExecutorMigration()
        let legacyOperation = try legacy.executor.apply(
            skillID: legacy.skillID,
            plan: legacy.plan,
            expectedOldBindings: [],
            approvedCopySource: legacy.ssotEvidence,
            approvedHistoricalMigration: legacy.approval,
            operationID: legacy.operationID,
            nowMilliseconds: 42
        )
        let legacyPreflight = try historicalApprovalMutation(
            legacyOperation.preflightPayload
        ) { backup, action in
            for key in [
                "skillID", "sourceScopeKey", "sourceLocator", "approvalOperationID",
                "sourceRootIdentity", "sourceEntryIdentity", "sourceContent",
                "sourcePhysicalTree", "targetLocator", "sourceRootLocator",
            ] {
                backup.removeValue(forKey: key)
            }
            action.removeValue(forKey: "localOriginCleanup")
        }
        try validateHistoricalPayloads(
            legacyOperation,
            preflightData: legacyPreflight
        )

        let fixture = try await HistoricalMigrationFixture(
            content: "# Bound",
            sourceScope: .agent(
                adapterCode: SkillPlatform.codex.storageKey,
                pathVariant: SkillPlatform.codex.dedicatedDistributionRelativePath
            )
        )
        let prepared = try await fixture.prepareExecutorMigration(existingBinding: true)
        let oldBindings = try prepared.executor.bindingStore.load(skillID: prepared.skillID)
        let operation = try prepared.executor.apply(
            skillID: prepared.skillID,
            plan: prepared.plan,
            expectedOldBindings: oldBindings,
            approvedCopySource: prepared.ssotEvidence,
            approvedHistoricalMigration: prepared.approval,
            operationID: prepared.operationID,
            nowMilliseconds: 42
        )
        let legacyUnbound = try historicalApprovalMutation(
            operation.preflightPayload
        ) { backup, action in
            for key in [
                "skillID", "sourceScopeKey", "sourceLocator", "approvalOperationID",
                "sourceRootIdentity", "sourceEntryIdentity", "sourceContent",
                "sourcePhysicalTree", "targetLocator", "sourceRootLocator",
            ] {
                backup.removeValue(forKey: key)
            }
            action.removeValue(forKey: "localOriginCleanup")
        }
        #expect(throws: DistributionOperationStoreError.invalidRecord) {
            try validateHistoricalPayloads(operation, preflightData: legacyUnbound)
        }

        let mismatchedIdentity = try historicalApprovalMutation(
            operation.preflightPayload
        ) { backup, _ in
            backup["sourceEntryIdentity"] = Data(
                repeating: 0,
                count: ManagedItemIdentityCodec.encodedByteCount
            ).base64EncodedString()
        }
        #expect(throws: DistributionOperationStoreError.invalidRecord) {
            try validateHistoricalPayloads(operation, preflightData: mismatchedIdentity)
        }

        let arbitraryRoot = try historicalApprovalMutation(
            operation.preflightPayload
        ) { backup, _ in
            backup["sourceRootLocator"] = "/tmp/victim"
        }
        #expect(throws: DistributionOperationStoreError.invalidRecord) {
            try validateHistoricalPayloads(operation, preflightData: arbitraryRoot)
        }
    }

    @Test("SSOT replacement after backup fails before distribution mutation")
    func rejectsSSOTReplacementAfterBackup() async throws {
        let replacement = HistoricalSSOTReplacement()
        var hooks = JournaledSSOTWriterHooks()
        hooks.historicalMigrationBackupPublished = replacement.replace
        let fixture = try await HistoricalMigrationFixture(
            content: "# Existing",
            writerHooks: hooks
        )
        let snapshot = try fixture.workspace.snapshot(content: "# Existing")
        let payload = try fixture.workspace.payload(name: "Existing", snapshot: snapshot)
        _ = try await fixture.writer.create(payload: payload, sourceSnapshot: snapshot)
        let prepared = try await fixture.prepare()
        let service = fixture.service()
        let preview = try await service.prepare(
            audit: prepared.audit,
            observation: prepared.observation,
            importAction: .claimExisting
        )
        replacement.arm(
            fixture.workspace.root.appendingPathComponent(
                payload.skill.skillID.directoryName,
                isDirectory: true
            )
        )

        await #expect(throws: HistoricalSkillMigrationError.stalePreview) {
            _ = try await service.confirm(preview.token)
        }

        #expect(try fixture.workspace.integer("SELECT count(*) FROM skill_backups") == 1)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_operations") == 0)
        #expect(try fixture.workspace.integer("SELECT count(*) FROM distribution_bindings") == 0)
        #expect(try !fixture.isSourceSymlink())
        #expect(
            try Data(contentsOf: fixture.sourceURL.appendingPathComponent("SKILL.md"))
                == Data("# Existing".utf8)
        )
    }
}

private func validateHistoricalPayloads(
    _ operation: DistributionOperationRecord,
    preflightData: Data
) throws {
    try DistributionOperationPayloadV2Validator.validateActionPayloads(
        operationID: operation.operationID,
        skillID: operation.skillID,
        oldBindings: try DistributionOperationPayloadCodec.decode(
            [DistributionBindingWireV2].self,
            from: operation.oldBindings
        ),
        newBindings: try DistributionOperationPayloadCodec.decode(
            [DistributionBindingWireV2].self,
            from: operation.newBindings
        ),
        planData: operation.planPayload,
        preflightData: preflightData,
        runtimeData: operation.runtimePayload,
        phase: operation.phase,
        outcome: operation.outcome,
        forwardCursor: operation.forwardCursor,
        rollbackCursor: operation.rollbackCursor,
        cleanupCursor: operation.cleanupCursor
    )
}

private func historicalApprovalMutation(
    _ data: Data,
    _ mutate: (inout [String: Any], inout [String: Any]) -> Void
) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var actions = root["actions"] as? [[String: Any]],
          var action = actions.first,
          var backup = action["historicalMigrationBackup"] as? [String: Any] else {
        throw DistributionOperationStoreError.invalidRecord
    }
    mutate(&backup, &action)
    action["historicalMigrationBackup"] = backup
    actions[0] = action
    root["actions"] = actions
    return try JSONSerialization.data(
        withJSONObject: root,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private final class HistoricalSSOTReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private var target: URL?

    func arm(_ target: URL) {
        lock.withLock { self.target = target }
    }

    func replace(_: SkillID) throws {
        let target = lock.withLock {
            defer { self.target = nil }
            return self.target
        }
        guard let target else { return }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("# Replaced".utf8).write(
            to: target.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
    }
}

private final class HistoricalForwardInterruption: @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var fired = false

    func reach(_ checkpoint: DistributionFilesystemCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard checkpoint == .afterCreateSync, !fired else { return }
        fired = true
        throw Failure()
    }
}

private final class HistoricalCommittedInterruption: @unchecked Sendable {
    struct Failure: Error {}

    private let point: HistoricalSkillMigrationRecoveryTests.CommittedRecoveryPoint
    private let lock = NSLock()
    private var fired = false

    init(point: HistoricalSkillMigrationRecoveryTests.CommittedRecoveryPoint) {
        self.point = point
    }

    func databaseCommitted() throws {
        guard point == .databaseCommitted else { return }
        try fire()
    }

    func filesystem(_ checkpoint: DistributionFilesystemCheckpoint) throws {
        guard point == .cleaning, checkpoint == .beforeCleanup else { return }
        try fire()
    }

    private func fire() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        throw Failure()
    }
}
