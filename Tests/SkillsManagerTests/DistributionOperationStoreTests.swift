import Foundation
import Testing

@testable import SkillsManager

@Suite("Distribution operation journal")
struct DistributionOperationStoreTests {
    @Test("insert, progress, repair and complete are durable")
    func journalLifecycle() throws {
        try withDistributionJournalFixture { connection, operationStore, ownershipStore, skillID in
            let draft = try DistributionOperationDraft(
                skillID: skillID,
                oldBindings: Data([1]),
                newBindings: Data([2]),
                planPayload: Data([3]),
                preflightPayload: Data([4]),
                runtimePayload: Data([5]),
                createdAtMilliseconds: 10
            )
            let inserted = try operationStore.insertPrepared(draft)
            #expect(try operationStore.load(inserted.operationID) == inserted)

            try operationStore.updateProgress(
                operationID: inserted.operationID,
                phase: .applying,
                forwardCursor: 1,
                rollbackCursor: 0,
                cleanupCursor: 0,
                runtimePayload: Data([6]),
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
}

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
