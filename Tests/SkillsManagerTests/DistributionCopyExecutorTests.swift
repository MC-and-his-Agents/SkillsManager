import Foundation
import Testing

@testable import SkillsManager

@Suite("Distribution Copy executor", .serialized)
struct DistributionCopyExecutorTests {
    @Test("creates, refreshes, and removes a managed Copy")
    func lifecycle() throws {
        let fixture = try CopyExecutorFixture()
        defer { fixture.cleanup() }

        let create = try fixture.plan(.global(fixture.slug))
        #expect(create.filesystemActions.map(\.kind) == [.createCopy])
        let created = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: create,
            expectedOldBindings: [],
            nowMilliseconds: 10
        )
        #expect(created.phase == .completed)
        #expect(created.outcome == .applied)
        let first = try #require(
            fixture.bindingStore.load(skillID: fixture.skillID).first
        )
        #expect(first.syncMode == .copy)
        #expect(first.copyBaseline?.appliedOperationID == created.operationID)
        let operationCount = try fixture.connection.querySingleInt(
            "SELECT count(*) FROM distribution_operations"
        )
        #expect(try fixture.executor.dryRun(
            skillID: fixture.skillID,
            currentBindings: [first],
            desiredConfiguration: fixture.configuration(.global(fixture.slug)),
            requiredAdapterCodes: fixture.globalReaders
        ).status == .noOp)
        #expect(try fixture.connection.querySingleInt(
            "SELECT count(*) FROM distribution_operations"
        ) == operationCount)
        #expect(try fixture.bindingStore.load(skillID: fixture.skillID) == [first])

        try Data("updated".utf8).write(
            to: fixture.ssot.appendingPathComponent("SKILL.md")
        )
        let refresh = try fixture.plan(.global(fixture.slug))
        #expect(refresh.filesystemActions.map(\.kind) == [.refreshCopy])
        let refreshed = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: refresh,
            expectedOldBindings: [first],
            nowMilliseconds: 20
        )
        let second = try #require(
            fixture.bindingStore.load(skillID: fixture.skillID).first
        )
        #expect(second.copyBaseline?.appliedOperationID == refreshed.operationID)
        #expect(second.copyBaseline != first.copyBaseline)

        let remove = try fixture.plan(.disabled)
        #expect(remove.filesystemActions.map(\.kind) == [.removeCopy])
        let removed = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: remove,
            expectedOldBindings: [second],
            nowMilliseconds: 30
        )
        #expect(removed.outcome == .applied)
        #expect(try fixture.bindingStore.load(skillID: fixture.skillID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.copyURL.path))
    }

    @Test("physical drift blocks mutation without writes")
    func physicalDriftBlocksMutation() throws {
        let fixture = try CopyExecutorFixture()
        defer { fixture.cleanup() }
        let create = try fixture.plan(.global(fixture.slug))
        _ = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: create,
            expectedOldBindings: [],
            nowMilliseconds: 10
        )
        try Data("finder".utf8).write(
            to: fixture.copyURL.appendingPathComponent(".DS_Store")
        )
        let plan = try fixture.plan(.disabled)
        #expect(plan.status == .blocked)
        #expect(plan.conflicts.map(\.reason) == [.copyPhysicalDrift])
        #expect(FileManager.default.fileExists(atPath: fixture.copyURL.path))
    }

    @Test("finishes database-committed cleanup idempotently after restart")
    func recoversCommittedCleanup() throws {
        let fixture = try CopyExecutorFixture()
        defer { fixture.cleanup() }
        let create = try fixture.plan(.global(fixture.slug))
        _ = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: create,
            expectedOldBindings: [],
            nowMilliseconds: 10
        )
        let old = try fixture.bindingStore.load(skillID: fixture.skillID)
        try Data("refresh".utf8).write(
            to: fixture.ssot.appendingPathComponent("SKILL.md")
        )
        let refresh = try fixture.plan(.global(fixture.slug))
        let completed = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: refresh,
            expectedOldBindings: old,
            nowMilliseconds: 20
        )
        try fixture.connection.execute(
            """
            UPDATE distribution_operations
            SET phase = 'databaseCommitted', outcome = NULL, cleanup_cursor = 0
            WHERE operation_id = X'\(completed.operationID.bytes.hexString)'
            """
        )

        try fixture.executor.recoverAll()
        try fixture.executor.recoverAll()

        let recovered = try fixture.operationStore.load(completed.operationID)
        #expect(recovered.phase == .completed)
        #expect(recovered.outcome == .applied)
        #expect(try fixture.operationStore.recoverableOperations().isEmpty)
    }

    @Test("preserves a changed quarantine and marks repair")
    func changedQuarantineNeedsRepair() throws {
        let interruption = CopyCheckpointInterruption(target: .beforeCleanup)
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
        try Data("refresh".utf8).write(
            to: fixture.ssot.appendingPathComponent("SKILL.md")
        )
        #expect(throws: CopyCheckpointInterruption.Failure.self) {
            _ = try fixture.executor.apply(
                skillID: fixture.skillID,
                plan: fixture.plan(.global(fixture.slug)),
                expectedOldBindings: old,
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
        try Data("local edit".utf8).write(to: quarantinedFile)
        try fixture.executor.recoverAll()
        #expect(try fixture.operationStore.repairRequiredOperations().count == 1)
        #expect(FileManager.default.fileExists(atPath: quarantinedFile.path))
        #expect(try String(
            contentsOf: fixture.copyURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "refresh")
    }

    @Test("converts safely between Symlink and Copy")
    func convertsModes() throws {
        let fixture = try CopyExecutorFixture()
        defer { fixture.cleanup() }
        let symlinkExecutor = try DistributionSymlinkExecutor(
            connection: fixture.connection,
            fileSystem: fixture.fileSystem,
            nowMilliseconds: { 5 }
        )
        let symlinkPlan = try symlinkExecutor.dryRun(
            skillID: fixture.skillID,
            currentBindings: [],
            desiredScope: .global(fixture.slug),
            requiredAdapterCodes: fixture.globalReaders
        )
        _ = try symlinkExecutor.apply(
            skillID: fixture.skillID,
            plan: symlinkPlan,
            expectedOldBindings: [],
            expectedOldOwnership: [],
            nowMilliseconds: 5
        )
        let symlinkBinding = try fixture.bindingStore.load(
            skillID: fixture.skillID
        )
        let toCopy = try fixture.executor.dryRun(
            skillID: fixture.skillID,
            currentBindings: symlinkBinding,
            desiredConfiguration: fixture.configuration(.global(fixture.slug)),
            requiredAdapterCodes: fixture.globalReaders
        )
        #expect(toCopy.filesystemActions.map(\.kind) == [.replaceSymlinkWithCopy])
        _ = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: toCopy,
            expectedOldBindings: symlinkBinding,
            nowMilliseconds: 10
        )

        let copyBinding = try fixture.bindingStore.load(skillID: fixture.skillID)
        let toLink = try fixture.executor.dryRun(
            skillID: fixture.skillID,
            currentBindings: copyBinding,
            desiredConfiguration: DistributionDesiredConfiguration(
                scope: .global(fixture.slug),
                syncMode: .symlink
            ),
            requiredAdapterCodes: fixture.globalReaders
        )
        #expect(toLink.filesystemActions.map(\.kind) == [.replaceCopyWithSymlink])
        _ = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: toLink,
            expectedOldBindings: copyBinding,
            nowMilliseconds: 20
        )

        let final = try #require(
            fixture.bindingStore.load(skillID: fixture.skillID).first
        )
        #expect(final.syncMode == .symlink)
        #expect(final.copyBaseline == nil)
        #expect(try fixture.ownershipStore.load(
            skillID: fixture.skillID
        ).count == 1)
    }

    @Test("rejects a stale same-slug plan without residue")
    func sameSlugCompetition() throws {
        let fixture = try CopyExecutorFixture()
        defer { fixture.cleanup() }
        let competingSkillID = SkillID(
            UUID(uuidString: "11112222-3333-4444-8555-666677778888")!
        )
        try fixture.addSkill(competingSkillID, contents: "competing")
        let firstPlan = try fixture.plan(.global(fixture.slug))
        let competingPlan = try fixture.plan(
            skillID: competingSkillID,
            scope: .global(fixture.slug)
        )
        _ = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: firstPlan,
            expectedOldBindings: [],
            nowMilliseconds: 10
        )
        #expect(throws: DistributionSymlinkExecutorError.self) {
            _ = try fixture.executor.apply(
                skillID: competingSkillID,
                plan: competingPlan,
                expectedOldBindings: [],
                nowMilliseconds: 20
            )
        }
        #expect(try fixture.bindingStore.load(skillID: competingSkillID).isEmpty)
        #expect(try fixture.operationStore.recoverableOperations().isEmpty)
        #expect(try fixture.operationStore.repairRequiredOperations().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.copyURL.path))
    }

    @Test("rejects unknown journal versions and tampered v2 payloads")
    func rejectsInvalidJournal() throws {
        let fixture = try CopyExecutorFixture()
        defer { fixture.cleanup() }
        let completed = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: fixture.plan(.global(fixture.slug)),
            expectedOldBindings: [],
            nowMilliseconds: 10
        )

        #expect(throws: SQLiteStoreError.self) {
            try fixture.connection.execute(
                """
                UPDATE distribution_operations SET format_version = 3
                WHERE operation_id = X'\(completed.operationID.bytes.hexString)'
                """
            )
        }
        var tamperedObject = try #require(
            JSONSerialization.jsonObject(
                with: completed.preflightPayload
            ) as? [String: Any]
        )
        var actions = try #require(
            tamperedObject["actions"] as? [[String: Any]]
        )
        actions[0]["slug"] = "other"
        tamperedObject["actions"] = actions
        let tampered = try JSONSerialization.data(
            withJSONObject: tamperedObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let update = try fixture.connection.prepare(
            """
            UPDATE distribution_operations SET preflight_payload = ?
            WHERE operation_id = ?
            """
        )
        try update.bind(tampered, at: 1)
        try update.bind(completed.operationID.bytes, at: 2)
        _ = try update.step()
        #expect(throws: DistributionOperationStoreError.invalidRecord) {
            _ = try fixture.operationStore.load(completed.operationID)
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

final class CopyExecutorFixture {
    let home: URL
    let skillID = SkillID(
        UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!
    )
    let ssot: URL
    let copyURL: URL
    let slug: DefaultDistributionSlug
    let connection: SQLiteConnection
    let fileSystem: DistributionSymlinkFileSystem
    let executor: DistributionCopyExecutor
    let bindingStore: DistributionBindingStore
    let operationStore: DistributionOperationStore
    let ownershipStore: DistributionLinkOwnershipStore

    init(hooks: DistributionFilesystemTestHooks = .init()) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "copy-executor-\(UUID().uuidString)",
            isDirectory: true
        )
        ssot = home
            .appendingPathComponent(".SkillsManager/skills", isDirectory: true)
            .appendingPathComponent(skillID.directoryName, isDirectory: true)
        copyURL = home.appendingPathComponent(
            ".agents/skills/demo",
            isDirectory: true
        )
        slug = try DefaultDistributionSlug(validating: "demo")
        try FileManager.default.createDirectory(
            at: ssot,
            withIntermediateDirectories: true
        )
        try Data("demo".utf8).write(to: ssot.appendingPathComponent("SKILL.md"))
        connection = try SkillSchemaMigrator.open(
            at: home.appendingPathComponent("manager.sqlite")
        )
        try connection.execute(
            """
            INSERT INTO skills(
              skill_id, display_name, default_distribution_slug, default_slug_key,
              fingerprint_algorithm_version, content_fingerprint, status,
              created_at_ms, updated_at_ms, db_revision
            ) VALUES (
              X'00112233445546778899aabbccddeeff', 'Demo', 'demo', 'demo',
              1, X'\(String(repeating: "ab", count: 32))', 'managed', 0, 0, 0
            )
            """
        )
        fileSystem = try DistributionSymlinkFileSystem(homeURL: home, hooks: hooks)
        executor = try DistributionCopyExecutor(
            connection: connection,
            fileSystem: fileSystem,
            nowMilliseconds: { 10 }
        )
        bindingStore = DistributionBindingStore(connection: connection)
        operationStore = try DistributionOperationStore(connection: connection)
        ownershipStore = DistributionLinkOwnershipStore(connection: connection)
    }

    var globalReaders: Set<String> {
        Set(DistributionTargetCatalog.current.globalReaders.map(\.storageKey))
    }

    func configuration(
        _ scope: DistributionDesiredScope
    ) -> DistributionDesiredConfiguration {
        DistributionDesiredConfiguration(scope: scope, syncMode: .copy)
    }

    func plan(_ scope: DistributionDesiredScope) throws -> DistributionPlan {
        try plan(skillID: skillID, scope: scope)
    }

    func plan(
        skillID: SkillID,
        scope: DistributionDesiredScope
    ) throws -> DistributionPlan {
        try executor.dryRun(
            skillID: skillID,
            currentBindings: bindingStore.load(skillID: skillID),
            desiredConfiguration: configuration(scope),
            requiredAdapterCodes: scope.requiredAdapterCodes
        )
    }

    func addSkill(_ skillID: SkillID, contents: String) throws {
        let directory = home
            .appendingPathComponent(".SkillsManager/skills", isDirectory: true)
            .appendingPathComponent(skillID.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try Data(contents.utf8).write(
            to: directory.appendingPathComponent("SKILL.md")
        )
        let statement = try connection.prepare(
            """
            INSERT INTO skills(
              skill_id, display_name, default_distribution_slug, default_slug_key,
              fingerprint_algorithm_version, content_fingerprint, status,
              created_at_ms, updated_at_ms, db_revision
            ) VALUES (?, 'Competing', 'demo', 'demo', 1, zeroblob(32), 'managed', 0, 0, 0)
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        _ = try statement.step()
    }

    func lastOperation() throws -> DistributionOperationRecord {
        let statement = try connection.prepare(
            "SELECT operation_id FROM distribution_operations ORDER BY created_at_ms DESC LIMIT 1"
        )
        guard try statement.step(), let bytes = statement.blob(at: 0) else {
            throw CopyCheckpointInterruption.Failure()
        }
        return try operationStore.load(SSOTOperationID(bytes: bytes))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}

final class CopyCheckpointInterruption: @unchecked Sendable {
    struct Failure: Error {}

    private let target: DistributionFilesystemCheckpoint
    private let lock = NSLock()
    private var fired = false

    init(target: DistributionFilesystemCheckpoint) {
        self.target = target
    }

    func reach(_ checkpoint: DistributionFilesystemCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard checkpoint == target, !fired else { return }
        fired = true
        throw Failure()
    }
}
