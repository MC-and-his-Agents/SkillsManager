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
