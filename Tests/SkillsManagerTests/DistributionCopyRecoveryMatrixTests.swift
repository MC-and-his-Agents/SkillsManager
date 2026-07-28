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
}
