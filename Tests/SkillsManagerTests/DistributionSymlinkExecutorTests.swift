import Foundation
import Testing

@testable import SkillsManager

@Suite("DistributionSymlinkExecutor", .serialized)
struct DistributionSymlinkExecutorTests {
    @Test("applies a global plan and persists binding ownership")
    func appliesGlobalPlan() throws {
        try withDistributionExecutorFixture { fixture in
            let record = try applyGlobal(fixture)
            #expect(record.phase == .completed)
            #expect(record.outcome == .applied)

            let bindings = try fixture.bindingStore.load(skillID: fixture.skillID)
            #expect(bindings.map(\.scope) == [.global])
            let ownership = try fixture.ownershipStore.load(skillID: fixture.skillID)
            #expect(ownership.map(\.targetScopeKey) == ["global"])
            guard let entry = DistributionTargetCatalog.current.entry(
                for: .global,
                slug: fixture.slug
            ) else {
                Issue.record("global distribution entry is missing")
                return
            }
            #expect(try fixture.fileSystem.observe(entry) == .symlink(
                rootIdentity: ownership[0].rootIdentity,
                entryIdentity: ownership[0].entryIdentity,
                target: ownership[0].absoluteLinkTarget
            ))
        }
    }

    @Test("recovers filesystemApplied using the journal old snapshot")
    func recoversFilesystemApplied() throws {
        try withCompletedTransition { fixture, transition in
            try rewindDatabase(fixture, transition: transition)
            try rewindOperation(
                fixture.connection,
                operationID: transition.agentOperation.operationID
            )

            try fixture.executor.recoverAll()

            let recovered = try fixture.operationStore.load(
                transition.agentOperation.operationID
            )
            #expect(recovered.phase == .completed)
            #expect(recovered.outcome == .applied)
            #expect(try fixture.bindingStore.load(skillID: fixture.skillID)
                == transition.agentBindings)
            #expect(try fixture.ownershipStore.load(skillID: fixture.skillID)
                == transition.agentOwnership)
        }
    }

    @Test("refuses recovery when old ownership no longer matches the journal")
    func rejectsOwnershipDrift() throws {
        try withCompletedTransition { fixture, transition in
            try rewindDatabase(fixture, transition: transition)
            let old = try #require(transition.globalOwnership.first)
            let drifted = try DistributionLinkOwnership(
                skillID: old.skillID,
                targetScopeKey: old.targetScopeKey,
                appliedOperationID: old.appliedOperationID,
                rootIdentity: old.rootIdentity,
                entryIdentity: old.entryIdentity,
                absoluteLinkTarget: old.absoluteLinkTarget,
                verifiedAtMilliseconds: old.verifiedAtMilliseconds + 1
            )
            _ = try fixture.ownershipStore.replace(
                skillID: fixture.skillID,
                expectedOld: transition.globalOwnership,
                desired: [drifted],
                appliedOperationID: old.appliedOperationID,
                nowMilliseconds: drifted.verifiedAtMilliseconds
            )
            try rewindOperation(
                fixture.connection,
                operationID: transition.agentOperation.operationID
            )

            try fixture.executor.recoverAll()

            let rejected = try fixture.operationStore.load(
                transition.agentOperation.operationID
            )
            #expect(rejected.outcome == .needsRepair)
            #expect(try fixture.ownershipStore.load(skillID: fixture.skillID) == [drifted])
        }
    }

    @Test("refuses recovery after the SSOT directory is replaced")
    func rejectsSSOTReplacement() throws {
        try withCompletedTransition { fixture, transition in
            try rewindDatabase(fixture, transition: transition)
            try rewindOperation(
                fixture.connection,
                operationID: transition.agentOperation.operationID
            )
            try FileManager.default.removeItem(at: fixture.ssot)
            try FileManager.default.createDirectory(
                at: fixture.ssot,
                withIntermediateDirectories: false
            )

            try fixture.executor.recoverAll()

            let rejected = try fixture.operationStore.load(
                transition.agentOperation.operationID
            )
            #expect(rejected.outcome == .needsRepair)
            #expect(try fixture.bindingStore.load(skillID: fixture.skillID)
                == transition.globalBindings)
        }
    }

    @Test("recovers a create that reached disk before its cursor checkpoint")
    func recoversPendingCreate() throws {
        try withDistributionExecutorFixture { fixture in
            let plan = try fixture.executor.dryRun(
                skillID: fixture.skillID,
                currentBindings: [],
                desiredScope: .global(fixture.slug),
                requiredAdapterCodes: Set(
                    DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
                )
            )
            guard let action = plan.filesystemActions.first else {
                Issue.record("create action is missing")
                return
            }
            let operation = try fixture.executor.apply(
                skillID: fixture.skillID,
                plan: plan,
                expectedOldBindings: [],
                expectedOldOwnership: [],
                nowMilliseconds: 10
            )
            let binding = try #require(try fixture.bindingStore.load(skillID: fixture.skillID).first)
            let ownership = try #require(try fixture.ownershipStore.load(skillID: fixture.skillID).first)
            try fixture.fileSystem.removeCreated(
                action.entry,
                expected: DistributionSymlinkEvidence(
                    rootIdentity: ownership.rootIdentity,
                    entryIdentity: ownership.entryIdentity,
                    absoluteTarget: ownership.absoluteLinkTarget
                )
            )
            _ = try fixture.ownershipStore.replace(
                skillID: fixture.skillID,
                expectedOld: [ownership],
                desired: [],
                appliedOperationID: operation.operationID,
                nowMilliseconds: 20
            )
            _ = try fixture.bindingStore.replace(
                skillID: fixture.skillID,
                expectedOld: [binding],
                desired: [],
                nowMilliseconds: 20
            )
            let rootIdentity = try fixture.fileSystem.ensureRoot(for: action.entry.target.scope)
            _ = try fixture.fileSystem.create(
                action.entry,
                absoluteTarget: fixture.ssot.path,
                expectedRootIdentity: rootIdentity
            )
            try rewindOperation(
                fixture.connection,
                operationID: operation.operationID,
                runtimePayload: try pendingRuntime(
                    rootIdentity: rootIdentity,
                    target: fixture.ssot.path,
                    actionIndex: 0,
                    kind: "create_symlink"
                )
            )
            try fixture.executor.recoverAll()

            let recovered = try fixture.operationStore.load(operation.operationID)
            #expect(recovered.outcome == .rolledBack)
            #expect(try fixture.fileSystem.observe(action.entry) == .missing(
                rootIdentity: rootIdentity
            ))
        }
    }

    @Test("recovers a remove that reached quarantine before its cursor checkpoint")
    func recoversPendingRemove() throws {
        try withDistributionExecutorFixture { fixture in
            let globalOperation = try applyGlobal(fixture)
            let oldBinding = try #require(
                try fixture.bindingStore.load(skillID: fixture.skillID).first
            )
            let oldOwnership = try #require(
                try fixture.ownershipStore.load(skillID: fixture.skillID).first
            )
            let plan = try fixture.executor.dryRun(
                skillID: fixture.skillID,
                currentBindings: [oldBinding],
                desiredScope: .disabled,
                requiredAdapterCodes: []
            )
            let action = try #require(plan.filesystemActions.first)
            let operation = try fixture.executor.apply(
                skillID: fixture.skillID,
                plan: plan,
                expectedOldBindings: [oldBinding],
                expectedOldOwnership: [oldOwnership],
                nowMilliseconds: 20
            )
            let restoredRoot = try fixture.fileSystem.ensureRoot(for: action.entry.target.scope)
            let recreated = try fixture.fileSystem.create(
                action.entry,
                absoluteTarget: oldOwnership.absoluteLinkTarget,
                expectedRootIdentity: restoredRoot
            )
            let rewoundOwnership = try DistributionLinkOwnership(
                skillID: fixture.skillID,
                targetScopeKey: oldOwnership.targetScopeKey,
                appliedOperationID: globalOperation.operationID,
                rootIdentity: recreated.rootIdentity,
                entryIdentity: recreated.entryIdentity,
                absoluteLinkTarget: recreated.absoluteTarget,
                verifiedAtMilliseconds: 30
            )
            _ = try fixture.bindingStore.replace(
                skillID: fixture.skillID,
                expectedOld: [],
                desired: [oldBinding.intent],
                nowMilliseconds: 30
            )
            _ = try fixture.ownershipStore.replace(
                skillID: fixture.skillID,
                expectedOld: [],
                desired: [rewoundOwnership],
                appliedOperationID: globalOperation.operationID,
                nowMilliseconds: 30
            )
            _ = try fixture.fileSystem.quarantine(
                action.entry,
                expected: DistributionSymlinkEvidence(
                    rootIdentity: rewoundOwnership.rootIdentity,
                    entryIdentity: rewoundOwnership.entryIdentity,
                    absoluteTarget: rewoundOwnership.absoluteLinkTarget
                ),
                operationID: operation.operationID.uuid,
                actionIndex: 0
            )
            try rewindOperation(
                fixture.connection,
                operationID: operation.operationID,
                runtimePayload: try pendingRuntime(
                    oldOwnership: operation.runtimePayload,
                    oldOwnershipOverride: [rewoundOwnership],
                    rootIdentity: rewoundOwnership.rootIdentity,
                    entryIdentity: rewoundOwnership.entryIdentity,
                    target: rewoundOwnership.absoluteLinkTarget,
                    actionIndex: 0,
                    kind: "remove_symlink",
                    temporaryName: DistributionSymlinkFileSystem.temporaryName(
                        operationID: operation.operationID.uuid,
                        actionIndex: 0
                    )
                )
            )
            try fixture.executor.recoverAll()

            let recovered = try fixture.operationStore.load(operation.operationID)
            #expect(recovered.outcome == .rolledBack)
            #expect(try fixture.fileSystem.observe(action.entry) == .symlink(
                rootIdentity: rewoundOwnership.rootIdentity,
                entryIdentity: rewoundOwnership.entryIdentity,
                target: rewoundOwnership.absoluteLinkTarget
            ))
        }
    }
}

private struct DistributionExecutorFixture {
    let home: URL
    let ssot: URL
    let skillID: SkillID
    let connection: SQLiteConnection
    let fileSystem: DistributionSymlinkFileSystem
    let executor: DistributionSymlinkExecutor
    let bindingStore: DistributionBindingStore
    let ownershipStore: DistributionLinkOwnershipStore
    let operationStore: DistributionOperationStore
    let slug: DefaultDistributionSlug
}

private struct CompletedTransition {
    let globalOperation: DistributionOperationRecord
    let globalBindings: [DistributionBinding]
    let globalOwnership: [DistributionLinkOwnership]
    let agentOperation: DistributionOperationRecord
    let agentBindings: [DistributionBinding]
    let agentOwnership: [DistributionLinkOwnership]
}

private func withDistributionExecutorFixture(
    _ body: (DistributionExecutorFixture) throws -> Void
) throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("distribution-executor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let skillID = SkillID(UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!)
    let ssot = home
        .appendingPathComponent(".SkillsManager/skills", isDirectory: true)
        .appendingPathComponent(skillID.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: ssot, withIntermediateDirectories: true)

    let connection = try SkillSchemaMigrator.open(
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
    let fileSystem = try DistributionSymlinkFileSystem(homeURL: home)
    try body(DistributionExecutorFixture(
        home: home,
        ssot: ssot,
        skillID: skillID,
        connection: connection,
        fileSystem: fileSystem,
        executor: try DistributionSymlinkExecutor(
            connection: connection,
            fileSystem: fileSystem,
            nowMilliseconds: { 10 }
        ),
        bindingStore: DistributionBindingStore(connection: connection),
        ownershipStore: DistributionLinkOwnershipStore(connection: connection),
        operationStore: try DistributionOperationStore(connection: connection),
        slug: try DefaultDistributionSlug(validating: "demo")
    ))
}

private func applyGlobal(
    _ fixture: DistributionExecutorFixture
) throws -> DistributionOperationRecord {
    let plan = try fixture.executor.dryRun(
        skillID: fixture.skillID,
        currentBindings: [],
        desiredScope: .global(fixture.slug),
        requiredAdapterCodes: Set(
            DistributionTargetCatalog.current.globalReaders.map(\.storageKey)
        )
    )
    #expect(plan.status == .executable)
    return try fixture.executor.apply(
        skillID: fixture.skillID,
        plan: plan,
        expectedOldBindings: [],
        expectedOldOwnership: [],
        nowMilliseconds: 10
    )
}

private func withCompletedTransition(
    _ body: (DistributionExecutorFixture, CompletedTransition) throws -> Void
) throws {
    try withDistributionExecutorFixture { fixture in
        let globalOperation = try applyGlobal(fixture)
        let globalBindings = try fixture.bindingStore.load(skillID: fixture.skillID)
        let globalOwnership = try fixture.ownershipStore.load(skillID: fixture.skillID)
        let plan = try fixture.executor.dryRun(
            skillID: fixture.skillID,
            currentBindings: globalBindings,
            desiredScope: .agents([.codex], fixture.slug),
            requiredAdapterCodes: [SkillPlatform.codex.storageKey]
        )
        #expect(plan.status == .executable)
        let agentOperation = try fixture.executor.apply(
            skillID: fixture.skillID,
            plan: plan,
            expectedOldBindings: globalBindings,
            expectedOldOwnership: globalOwnership,
            nowMilliseconds: 20
        )
        try body(fixture, CompletedTransition(
            globalOperation: globalOperation,
            globalBindings: globalBindings,
            globalOwnership: globalOwnership,
            agentOperation: agentOperation,
            agentBindings: try fixture.bindingStore.load(skillID: fixture.skillID),
            agentOwnership: try fixture.ownershipStore.load(skillID: fixture.skillID)
        ))
    }
}

private func rewindDatabase(
    _ fixture: DistributionExecutorFixture,
    transition: CompletedTransition
) throws {
    _ = try fixture.bindingStore.replace(
        skillID: fixture.skillID,
        expectedOld: transition.agentBindings,
        desired: transition.globalBindings.map(\.intent),
        nowMilliseconds: transition.globalBindings[0].updatedAtMilliseconds
    )
    _ = try fixture.ownershipStore.replace(
        skillID: fixture.skillID,
        expectedOld: [],
        desired: transition.globalOwnership,
        appliedOperationID: transition.globalOperation.operationID,
        nowMilliseconds: transition.globalOwnership[0].verifiedAtMilliseconds
    )
}

private func rewindOperation(
    _ connection: SQLiteConnection,
    operationID: SSOTOperationID,
    runtimePayload: Data? = nil
) throws {
    let statement = try connection.prepare(
        runtimePayload == nil
            ? """
              UPDATE distribution_operations
              SET phase = 'filesystemApplied', outcome = NULL, cleanup_cursor = 0,
                  last_error = NULL
              WHERE operation_id = ?
              """
            : """
              UPDATE distribution_operations
              SET phase = 'applying', outcome = NULL, forward_cursor = 0,
                  rollback_cursor = 0, cleanup_cursor = 0, runtime_payload = ?,
                  last_error = NULL
              WHERE operation_id = ?
              """
    )
    if let runtimePayload {
        try statement.bind(runtimePayload, at: 1)
        try statement.bind(operationID.bytes, at: 2)
    } else {
        try statement.bind(operationID.bytes, at: 1)
    }
    guard try !statement.step() else {
        throw DistributionOperationStoreError.invalidRecord
    }
}

private func pendingRuntime(
    oldOwnership: Data? = nil,
    oldOwnershipOverride: [DistributionLinkOwnership] = [],
    rootIdentity: ManagedItemIdentity,
    entryIdentity: ManagedItemIdentity? = nil,
    target: String,
    actionIndex: Int,
    kind: String,
    temporaryName: String? = nil
) throws -> Data {
    var object: [String: Any] = [
        "created": [],
        "removed": [],
        "pending": [[
            "actionIndex": actionIndex,
            "kind": kind,
            "rootIdentity": try ManagedItemIdentityCodec.encode(rootIdentity)
                .base64EncodedString(),
            "absoluteLinkTarget": target,
        ]],
    ]
    if !oldOwnershipOverride.isEmpty {
        object["oldOwnership"] = try oldOwnershipOverride.map {
            [
                "targetScopeKey": $0.targetScopeKey,
                "appliedOperationID": $0.appliedOperationID.bytes.base64EncodedString(),
                "rootIdentity": try ManagedItemIdentityCodec.encode($0.rootIdentity)
                    .base64EncodedString(),
                "entryIdentity": try ManagedItemIdentityCodec.encode($0.entryIdentity)
                    .base64EncodedString(),
                "absoluteLinkTarget": $0.absoluteLinkTarget,
                "verifiedAtMilliseconds": $0.verifiedAtMilliseconds,
            ]
        }
    } else if let oldOwnership {
        let decoded = try JSONSerialization.jsonObject(with: oldOwnership)
        object["oldOwnership"] = decoded
    }
    var pending = object["pending"] as! [[String: Any]]
    if let entryIdentity {
        pending[0]["entryIdentity"] = try ManagedItemIdentityCodec.encode(entryIdentity)
            .base64EncodedString()
    }
    if let temporaryName {
        pending[0]["temporaryName"] = temporaryName
    }
    object["pending"] = pending
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}
