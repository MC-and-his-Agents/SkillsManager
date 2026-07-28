import Foundation
import Testing

@testable import SkillsManager

@Suite("Distribution Copy recovery checkpoints", .serialized)
struct DistributionCopyRecoveryMatrixTests {
    @Test("creation interruptions roll back without residue")
    func creationInterruptions() throws {
        let checkpoints: [DistributionFilesystemCheckpoint] = [
            .beforeCopyStage,
            .afterCopyStageBeforeSync,
            .afterCopyStageSync,
            .beforeCopyPromote,
            .afterCopyPromoteBeforeSync,
            .afterCopyPromoteSync,
        ]
        for checkpoint in checkpoints {
            let interruption = CopyCheckpointInterruption(target: checkpoint)
            let fixture = try CopyExecutorFixture(hooks: .init(
                onCheckpoint: interruption.reach
            ))
            defer { fixture.cleanup() }

            #expect(throws: CopyCheckpointInterruption.Failure.self) {
                _ = try fixture.executor.apply(
                    skillID: fixture.skillID,
                    plan: fixture.plan(.global(fixture.slug)),
                    expectedOldBindings: [],
                    nowMilliseconds: 10
                )
            }

            #expect(try fixture.bindingStore.load(
                skillID: fixture.skillID
            ).isEmpty)
            #expect(try fixture.operationStore.recoverableOperations().isEmpty)
            #expect(try fixture.operationStore.repairRequiredOperations().isEmpty)
            #expect(try fixture.lastOperation().outcome == .rolledBack)
            #expect(!FileManager.default.fileExists(atPath: fixture.copyURL.path))
        }
    }

    @Test("removal interruptions restore the old Copy")
    func removalInterruptions() throws {
        let checkpoints: [DistributionFilesystemCheckpoint] = [
            .beforeRemoveRename,
            .afterRemoveRenameBeforeSync,
            .afterRemoveSync,
        ]
        for checkpoint in checkpoints {
            let interruption = CopyCheckpointInterruption(target: checkpoint)
            let fixture = try CopyExecutorFixture(hooks: .init(
                onCheckpoint: interruption.reach
            ))
            defer { fixture.cleanup() }
            _ = try fixture.executor.apply(
                skillID: fixture.skillID,
                plan: fixture.plan(.global(fixture.slug)),
                expectedOldBindings: [],
                nowMilliseconds: 10
            )
            let old = try fixture.bindingStore.load(skillID: fixture.skillID)

            #expect(throws: CopyCheckpointInterruption.Failure.self) {
                _ = try fixture.executor.apply(
                    skillID: fixture.skillID,
                    plan: fixture.plan(.disabled),
                    expectedOldBindings: old,
                    nowMilliseconds: 20
                )
            }

            #expect(try fixture.bindingStore.load(
                skillID: fixture.skillID
            ) == old)
            #expect(try fixture.operationStore.recoverableOperations().isEmpty)
            #expect(try fixture.operationStore.repairRequiredOperations().isEmpty)
            #expect(try fixture.lastOperation().outcome == .rolledBack)
            #expect(FileManager.default.fileExists(atPath: fixture.copyURL.path))
        }
    }

    @Test("filesystem-applied restart rolls back a sealed Copy journal")
    func filesystemAppliedRestart() throws {
        let fixture = try CopyExecutorFixture()
        defer { fixture.cleanup() }
        let completed = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: fixture.plan(.global(fixture.slug)),
            expectedOldBindings: [],
            nowMilliseconds: 10
        )
        let deleteBindings = try fixture.connection.prepare(
            "DELETE FROM distribution_bindings WHERE skill_id = ?"
        )
        try deleteBindings.bind(fixture.skillID.bytes, at: 1)
        _ = try deleteBindings.step()
        let deleteConfiguration = try fixture.connection.prepare(
            "DELETE FROM distribution_configurations WHERE skill_id = ?"
        )
        try deleteConfiguration.bind(fixture.skillID.bytes, at: 1)
        _ = try deleteConfiguration.step()
        let rewindOperation = try fixture.connection.prepare(
            """
            UPDATE distribution_operations
            SET phase = 'filesystemApplied', outcome = NULL, cleanup_cursor = 0
            WHERE operation_id = ?
            """
        )
        try rewindOperation.bind(completed.operationID.bytes, at: 1)
        _ = try rewindOperation.step()

        try fixture.executor.recoverAll()

        let recovered = try fixture.operationStore.load(completed.operationID)
        #expect(recovered.phase == .completed)
        #expect(recovered.outcome == .rolledBack)
        #expect(try fixture.operationStore.recoverableOperations().isEmpty)
        #expect(try fixture.operationStore.repairRequiredOperations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.copyURL.path))
    }
}
