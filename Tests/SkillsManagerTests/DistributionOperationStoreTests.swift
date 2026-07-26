import Foundation
import Testing

@testable import SkillsManager

@Suite("Distribution operation journal", .serialized)
struct DistributionOperationStoreTests {
    @Test("insert, progress, repair and complete are durable")
    func journalLifecycle() throws {
        try withDistributionJournalFixture { connection, operationStore, ownershipStore, skillID in
            let draft = try DistributionOperationDraft(
                skillID: skillID,
                oldBindings: Data("[]".utf8),
                newBindings: Data("[]".utf8),
                planPayload: Data(
                    #"{"binding_replacement":[],"bindings_changed":false,"conflicts":[],"filesystem_actions":[],"status":"executable"}"#.utf8
                ),
                preflightPayload: Data("[]".utf8),
                runtimePayload: Data(#"{"created":[],"removed":[]}"#.utf8),
                createdAtMilliseconds: 10
            )
            let inserted = try operationStore.insertPrepared(draft)
            #expect(try operationStore.load(inserted.operationID) == inserted)

            try operationStore.updateProgress(
                operationID: inserted.operationID,
                phase: .applying,
                forwardCursor: 0,
                rollbackCursor: 0,
                cleanupCursor: 0,
                runtimePayload: Data(#"{"created":[],"removed":[]}"#.utf8),
                attemptCount: 1,
                lastError: nil,
                updatedAtMilliseconds: 11
            )
            #expect(try operationStore.recoverableOperationIDs() == [inserted.operationID])
            try operationStore.markNeedsRepair(
                operationID: inserted.operationID,
                detail: "drift",
                updatedAtMilliseconds: 12
            )
            #expect((try operationStore.repairRequiredOperations()).count == 1)

            // A needsRepair operation is intentionally terminal for normal apply.
            #expect(throws: DistributionOperationStoreError.conflict) {
                try operationStore.complete(
                    operationID: inserted.operationID,
                    outcome: .applied,
                    updatedAtMilliseconds: 13
                )
            }
            _ = ownershipStore
            _ = connection
        }
    }

    @Test("canonical payload round trips and rejects non-canonical JSON")
    func canonicalPayload() throws {
        struct Value: Codable, Equatable { let b: Int; let a: Int }
        let encoded = try DistributionOperationPayloadCodec.encode(Value(b: 2, a: 1))
        #expect(try DistributionOperationPayloadCodec.decode(Value.self, from: encoded)
            == Value(b: 2, a: 1))
        #expect(throws: DistributionOperationPayloadError.self) {
            _ = try DistributionOperationPayloadCodec.decode(
                Value.self,
                from: Data(#"{"b":2,"a":1}"#.utf8)
            )
        }
    }

    @Test("typed payloads reject contradictions, unknown actions, and resource overflow")
    func typedPayloadValidation() throws {
        let skillID = SkillID(UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!)
        let plan = TestPlan(
            status: "executable",
            filesystemActions: [],
            bindingsChanged: false,
            bindingReplacement: [],
            conflicts: []
        )
        let common = try #require(try? DistributionOperationPayloadCodec.encode(plan))
        let draft = {
            try DistributionOperationDraft(
                skillID: skillID,
                oldBindings: Data("[]".utf8),
                newBindings: Data("[]".utf8),
                planPayload: common,
                preflightPayload: Data("[]".utf8),
                runtimePayload: Data(#"{"created":[],"removed":[]}"#.utf8),
                createdAtMilliseconds: 1
            )
        }
        _ = try draft()

        #expect(throws: DistributionOperationStoreError.invalidRecord) {
            _ = try DistributionOperationDraft(
                skillID: skillID,
                oldBindings: Data(
                    #"[{"adapter":null,"skillID":"11112222333344445555666677778888","scope":"global","slug":"demo","syncMode":"symlink"}]"#.utf8
                ),
                newBindings: Data("[]".utf8),
                planPayload: common,
                preflightPayload: Data("[]".utf8),
                runtimePayload: Data(#"{"created":[],"removed":[]}"#.utf8),
                createdAtMilliseconds: 1
            )
        }

        let overflow = TestPlan(
            status: "executable",
            filesystemActions: (0..<9).map {
                TestPlanAction(
                    action: "create_symlink",
                    targetScopeKey: "global",
                    targetLocator: "~/.agents/skills/skill-\($0)",
                    ssotLocator: "~/.SkillsManager/skills/\(skillID.directoryName)"
                )
            },
            bindingsChanged: false,
            bindingReplacement: [],
            conflicts: []
        )
        #expect(throws: DistributionOperationStoreError.invalidRecord) {
            _ = try DistributionOperationDraft(
                skillID: skillID,
                oldBindings: Data("[]".utf8),
                newBindings: Data("[]".utf8),
                planPayload: try DistributionOperationPayloadCodec.encode(overflow),
                preflightPayload: Data("[]".utf8),
                runtimePayload: Data(#"{"created":[],"removed":[]}"#.utf8),
                createdAtMilliseconds: 1
            )
        }
    }
}

private struct TestPlan: Codable {
    let status: String
    let filesystemActions: [TestPlanAction]
    let bindingsChanged: Bool
    let bindingReplacement: [TestPlanBinding]
    let conflicts: [TestPlanConflict]

    enum CodingKeys: String, CodingKey {
        case status
        case filesystemActions = "filesystem_actions"
        case bindingsChanged = "bindings_changed"
        case bindingReplacement = "binding_replacement"
        case conflicts
    }
}

private struct TestPlanAction: Codable {
    let action: String
    let targetScopeKey: String
    let targetLocator: String
    let ssotLocator: String

    enum CodingKeys: String, CodingKey {
        case action
        case targetScopeKey = "target_scope_key"
        case targetLocator = "target_locator"
        case ssotLocator = "ssot_locator"
    }
}

private struct TestPlanBinding: Codable {}
private struct TestPlanConflict: Codable {}

private func withDistributionJournalFixture(
    _ body: (
        SQLiteConnection,
        DistributionOperationStore,
        DistributionLinkOwnershipStore,
        SkillID
    ) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("distribution-journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let connection = try SkillSchemaMigrator.open(
        at: root.appendingPathComponent("manager.sqlite")
    )
    let skillID = SkillID(UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!)
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
    try body(
        connection,
        try DistributionOperationStore(connection: connection),
        DistributionLinkOwnershipStore(connection: connection),
        skillID
    )
}
