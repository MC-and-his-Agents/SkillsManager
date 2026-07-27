import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill deletion operation store", .serialized)
struct SkillDeletionOperationStoreTests {
    @Test("enforces one active operation and forward-only CAS transitions")
    func lifecycle() throws {
        try withSkillSchemaV9 { connection, root in
            let identity = try ManagedRootReference.capture(at: root).verifiedRoot().identity
            let store = try SkillDeletionOperationStore(connection: connection)
            let draft = try deletionDraft(identity: identity)
            let prepared = try store.insertPrepared(draft)
            #expect(try store.load(prepared.operationID) == prepared)
            #expect(throws: SkillDeletionOperationStoreError.conflict) {
                _ = try store.insertPrepared(try deletionDraft(
                    operationID: SSOTOperationID(
                        UUID(uuidString: "bbbbbbbb-2222-4333-8444-cccccccccccc")!
                    ),
                    identity: identity
                ))
            }

            let published = try deletionRecord(
                from: prepared,
                phase: .backupPublished,
                updated: 2
            )
            try store.transition(expected: prepared, to: published)
            #expect(try store.recoverable() == [published])

            let rolledBack = try deletionRecord(
                from: published,
                phase: .completed,
                outcome: .rolledBack,
                updated: 3
            )
            try store.transition(expected: published, to: rolledBack)
            #expect(try store.recoverable().isEmpty)
            #expect(throws: SkillDeletionOperationStoreError.conflict) {
                try store.transition(expected: prepared, to: published)
            }
        }
    }
}

private func deletionDraft(
    operationID: SSOTOperationID = SSOTOperationID(
        UUID(uuidString: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")!
    ),
    identity: ManagedItemIdentity
) throws -> SkillDeletionOperationDraft {
    try SkillDeletionOperationDraft(
        operationID: operationID,
        skillID: SkillID(
            UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!
        ),
        backupID: SkillBackupID(
            UUID(uuidString: "11112222-3333-4444-8555-666677778888")!
        ),
        domainPayload: Data("{\"skill\":\"demo\"}".utf8),
        expectationPayload: Data("{\"revision\":1}".utf8),
        distributionPlan: Data("{\"actions\":[]}".utf8),
        ssotIdentity: identity,
        quarantineLocator: "quarantine/aaaaaaaa",
        createdAtMilliseconds: 1
    )
}

private func deletionRecord(
    from old: SkillDeletionOperationRecord,
    phase: SkillDeletionPhase,
    outcome: SkillDeletionOutcome = .pending,
    cleanup: SkillDeletionCleanupState = .notApplicable,
    quarantineIdentity: ManagedItemIdentity? = nil,
    updated: Int64
) throws -> SkillDeletionOperationRecord {
    try SkillDeletionOperationRecord(
        operationID: old.operationID,
        skillID: old.skillID,
        backupID: old.backupID,
        phase: phase,
        outcome: outcome,
        cleanupState: cleanup,
        domainPayload: old.domainPayload,
        expectationPayload: old.expectationPayload,
        distributionPlan: old.distributionPlan,
        ssotIdentity: old.ssotIdentity,
        quarantineLocator: old.quarantineLocator,
        quarantineIdentity: quarantineIdentity,
        attemptCount: old.attemptCount,
        lastError: nil,
        createdAtMilliseconds: old.createdAtMilliseconds,
        updatedAtMilliseconds: updated
    )
}
