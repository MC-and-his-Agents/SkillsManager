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

    @Test("explicit discard checkpoints recover in v2 and v3")
    func discardCheckpointRecovery() async throws {
        let checkpoints: [DistributionFilesystemCheckpoint] = [
            .afterCopyStageSync,
            .afterRemoveSync,
            .afterCopyPromoteSync,
            .beforeCleanup,
        ]
        for formatVersion in [2, 3] {
            for checkpoint in checkpoints {
                let interruption = CopyCheckpointInterruption(
                    target: checkpoint,
                    isArmed: false
                )
                let fixture = try await DiscardRecoveryFixture.make(
                    formatVersion: formatVersion,
                    hooks: .init(onCheckpoint: interruption.reach)
                )
                defer { fixture.cleanup() }
                let discard = try fixture.prepareDiscard()
                interruption.arm()

                #expect(throws: CopyCheckpointInterruption.Failure.self) {
                    _ = try fixture.executor.apply(
                        skillID: fixture.skillID,
                        plan: discard.plan,
                        expectedOldBindings: discard.bindings,
                        approvedCopyDrift: discard.drift,
                        approvedCopySource: discard.source,
                        nowMilliseconds: 20
                    )
                }
                let interrupted = try fixture.lastOperation()
                #expect(interrupted.formatVersion == formatVersion)
                #expect(String(
                    data: interrupted.planPayload,
                    encoding: .utf8
                )?.contains("discard_copy_drift") == true)

                try fixture.executor.recoverAll()

                let recovered = try fixture.operationStore.load(
                    interrupted.operationID
                )
                #expect(recovered.phase == (
                    checkpoint == .beforeCleanup ? .completed : .rollingBack
                ))
                #expect(recovered.outcome == (
                    checkpoint == .beforeCleanup ? .applied : .needsRepair
                ))
                #expect(try fixture.bindingStore.load(
                    skillID: fixture.skillID
                ).count == 1)
                #expect(try String(
                    contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
                    encoding: .utf8
                ) == (
                    checkpoint == .beforeCleanup
                        ? fixture.restoredContents
                        : fixture.driftedContents
                ))
                #expect(try fixture.operationStore.recoverableOperations().isEmpty)
                #expect(try fixture.operationStore.repairRequiredOperations().count == (
                    checkpoint == .beforeCleanup ? 0 : 1
                ))
            }
        }
    }

    @Test("explicit discard preserves a changed quarantine in v2 and v3")
    func discardChangedQuarantineNeedsRepair() async throws {
        for formatVersion in [2, 3] {
            let interruption = CopyCheckpointInterruption(
                target: .beforeCleanup,
                isArmed: false
            )
            let fixture = try await DiscardRecoveryFixture.make(
                formatVersion: formatVersion,
                hooks: .init(onCheckpoint: interruption.reach)
            )
            defer { fixture.cleanup() }
            let discard = try fixture.prepareDiscard()
            interruption.arm()

            #expect(throws: CopyCheckpointInterruption.Failure.self) {
                _ = try fixture.executor.apply(
                    skillID: fixture.skillID,
                    plan: discard.plan,
                    expectedOldBindings: discard.bindings,
                    approvedCopyDrift: discard.drift,
                    approvedCopySource: discard.source,
                    nowMilliseconds: 20
                )
            }
            let operation = try fixture.lastOperation()
            let preflight = try DistributionOperationPayloadCodec.decode(
                DistributionOperationPreflightV2.self,
                from: operation.preflightPayload
            )
            let quarantine = try #require(preflight.actions.first?.quarantineName)
            let quarantinedFile = fixture.copyURL.deletingLastPathComponent()
                .appendingPathComponent(quarantine, isDirectory: true)
                .appendingPathComponent("SKILL.md")
            try Data("changed quarantine".utf8).write(to: quarantinedFile)

            try fixture.executor.recoverAll()

            #expect(operation.formatVersion == formatVersion)
            #expect(try fixture.operationStore.repairRequiredOperations().count == 1)
            #expect(FileManager.default.fileExists(atPath: quarantinedFile.path))
            #expect(try fixture.bindingStore.load(
                skillID: fixture.skillID
            ).count == 1)
            #expect(try String(
                contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) == fixture.restoredContents)
        }
    }

    @Test("executor rejects approved SSOT evidence after the source changes")
    func discardSourceRace() async throws {
        let fixture = try await DiscardRecoveryFixture.make(
            formatVersion: 2,
            hooks: .init()
        )
        defer { fixture.cleanup() }
        let discard = try fixture.prepareDiscard()
        let direct = try #require(fixture.direct)
        try Data("changed after approval".utf8).write(
            to: direct.ssot.appendingPathComponent("SKILL.md")
        )
        let operationCount = try fixture.connection.querySingleInt(
            "SELECT count(*) FROM distribution_operations"
        )

        #expect(throws: DistributionSymlinkExecutorError.conflict) {
            _ = try fixture.executor.apply(
                skillID: fixture.skillID,
                plan: discard.plan,
                expectedOldBindings: discard.bindings,
                approvedCopyDrift: discard.drift,
                approvedCopySource: discard.source,
                nowMilliseconds: 20
            )
        }
        #expect(try fixture.connection.querySingleInt(
            "SELECT count(*) FROM distribution_operations"
        ) == operationCount)
        #expect(try String(
            contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == fixture.driftedContents)
    }
}

private struct DiscardExecutorInput {
    let plan: DistributionPlan
    let bindings: [DistributionBinding]
    let drift: DistributionCopyEvidence
    let source: DistributionCopySourceEvidence
}

private final class DiscardRecoveryFixture {
    let workspace: WriterWorkspace?
    let direct: CopyExecutorFixture?
    let skillID: SkillID
    let copyURL: URL
    let slug: DefaultDistributionSlug
    let connection: SQLiteConnection
    let fileSystem: DistributionSymlinkFileSystem
    let executor: DistributionCopyExecutor
    let bindingStore: DistributionBindingStore
    let operationStore: DistributionOperationStore
    let driftedContents: String
    let restoredContents: String

    private init(
        direct: CopyExecutorFixture,
        driftedContents: String,
        restoredContents: String
    ) {
        workspace = nil
        self.direct = direct
        skillID = direct.skillID
        copyURL = direct.copyURL
        slug = direct.slug
        connection = direct.connection
        fileSystem = direct.fileSystem
        executor = direct.executor
        bindingStore = direct.bindingStore
        operationStore = direct.operationStore
        self.driftedContents = driftedContents
        self.restoredContents = restoredContents
    }

    private init(
        workspace: WriterWorkspace,
        skillID: SkillID,
        copyURL: URL,
        slug: DefaultDistributionSlug,
        connection: SQLiteConnection,
        fileSystem: DistributionSymlinkFileSystem,
        executor: DistributionCopyExecutor,
        driftedContents: String,
        restoredContents: String
    ) throws {
        self.workspace = workspace
        direct = nil
        self.skillID = skillID
        self.copyURL = copyURL
        self.slug = slug
        self.connection = connection
        self.fileSystem = fileSystem
        self.executor = executor
        bindingStore = DistributionBindingStore(connection: connection)
        operationStore = try DistributionOperationStore(connection: connection)
        self.driftedContents = driftedContents
        self.restoredContents = restoredContents
    }

    static func make(
        formatVersion: Int,
        hooks: DistributionFilesystemTestHooks
    ) async throws -> DiscardRecoveryFixture {
        if formatVersion == 2 {
            let direct = try CopyExecutorFixture(hooks: hooks)
            _ = try direct.executor.apply(
                skillID: direct.skillID,
                plan: direct.plan(.global(direct.slug)),
                expectedOldBindings: [],
                nowMilliseconds: 10
            )
            return DiscardRecoveryFixture(
                direct: direct,
                driftedContents: "locally changed",
                restoredContents: "demo"
            )
        }

        let workspace = try WriterWorkspace(distributionEnabled: true)
        let writer = try await workspace.openWriter()
        let parent = try await prepareParentCopy(workspace: workspace, writer: writer)
        let slug = try DefaultDistributionSlug(validating: "parent")
        let copyURL = workspace.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(slug.value, isDirectory: true)
        try Data("locally changed".utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let preview = try await writer.copyDriftDecisionPreview(
            parentSkillID: parent,
            scope: .global
        )
        let fork = try await writer.createCopyFork(preview)
        let connection = try SQLiteConnection(url: workspace.database)
        let fileSystem = try DistributionSymlinkFileSystem(
            homeURL: workspace.distributionHomeURL,
            hooks: hooks
        )
        return try DiscardRecoveryFixture(
            workspace: workspace,
            skillID: fork.childSkillID,
            copyURL: copyURL,
            slug: slug,
            connection: connection,
            fileSystem: fileSystem,
            executor: DistributionCopyExecutor(
                connection: connection,
                fileSystem: fileSystem,
                nowMilliseconds: { 20 }
            ),
            driftedContents: "fork local change",
            restoredContents: "locally changed"
        )
    }

    func prepareDiscard() throws -> DiscardExecutorInput {
        try Data(driftedContents.utf8).write(
            to: copyURL.appendingPathComponent("SKILL.md")
        )
        let bindings = try bindingStore.load(skillID: skillID)
        let binding = try #require(bindings.first)
        let baseline = try #require(binding.copyBaseline)
        let entry = try #require(DistributionTargetCatalog.current.entry(
            for: binding.scope,
            slug: binding.distributionSlug
        ))
        let drift = try fileSystem.captureCopy(
            entry,
            expectedRootIdentity: baseline.rootIdentity,
            expectedEntryIdentity: baseline.entryIdentity
        ).evidence
        let source = try fileSystem.copySource(for: skillID).decisionEvidence()
        let configured = try DistributionConfigurationStore(
            connection: connection
        ).load(skillID: skillID)
        return DiscardExecutorInput(
            plan: DistributionPlan(
                status: .executable,
                filesystemActions: [DistributionFilesystemAction(
                    kind: .discardCopyDrift,
                    entry: entry,
                    ssotLocator: DistributionTargetCatalog.current.ssotLocator(
                        for: skillID
                    )
                )],
                bindingsChanged: false,
                bindingReplacement: bindings.map(\.intent),
                configurationChanged: false,
                expectedOldConfigured: configured,
                desiredConfigured: configured,
                conflicts: []
            ),
            bindings: bindings,
            drift: drift,
            source: source
        )
    }

    func lastOperation() throws -> DistributionOperationRecord {
        let statement = try connection.prepare(
            "SELECT operation_id FROM distribution_operations ORDER BY rowid DESC LIMIT 1"
        )
        guard try statement.step(), let bytes = statement.blob(at: 0) else {
            throw CopyCheckpointInterruption.Failure()
        }
        return try operationStore.load(SSOTOperationID(bytes: bytes))
    }

    func cleanup() {
        direct?.cleanup()
    }
}
