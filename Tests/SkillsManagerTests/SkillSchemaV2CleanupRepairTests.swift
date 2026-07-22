import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v2 cleanup repair")
struct SkillSchemaV2CleanupRepairTests {
    enum TerminalOutcome: String, CaseIterable {
        case applied
        case rolledBack
    }

    enum CleanupDebtDrift: CaseIterable {
        case role
        case locator
        case rootIdentity
        case itemIdentity
        case fingerprint

        var updateSQL: String {
            switch self {
            case .role:
                "UPDATE cleanup_debts SET item_role = 'staging'"
            case .locator:
                "UPDATE cleanup_debts SET recovery_locator = '.skillsmanager-tmp-foreign'"
            case .rootIdentity:
                "UPDATE cleanup_debts SET expected_root_identity = \(v2Blob(v2OtherIdentity))"
            case .itemIdentity:
                "UPDATE cleanup_debts SET expected_item_identity = \(v2Blob(v2ItemIdentity))"
            case .fingerprint:
                "UPDATE cleanup_debts SET expected_content_fingerprint = \(v2Blob(v2Fingerprint))"
            }
        }
    }

    @Test("terminal cleanup debt can only enter durable repair", arguments: TerminalOutcome.allCases)
    func persistsIrreversibleCleanupRepair(_ outcome: TerminalOutcome) throws {
        let location = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let connection = try SkillSchemaMigrator.open(at: location.database)
        try preparePendingDebt(outcome, connection: connection)

        try connection.execute(
            "UPDATE skill_operations SET cleanup_state = 'needsRepair', updated_at_ms = 4"
        )

        #expect(try connection.querySingleText(
            "SELECT phase || ':' || outcome || ':' || cleanup_state FROM skill_operations"
        ) == "completed:\(outcome.rawValue):needsRepair")
        #expect(try connection.querySingleText(
            "SELECT lower(hex(cleanup_debt_id)) FROM skill_operations"
        ) == v2DebtA)
        #expect(v2SQLIsRejected(
            connection,
            "UPDATE skill_operations SET cleanup_state = 'completed', cleanup_debt_id = NULL, "
                + "updated_at_ms = 5"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "UPDATE skill_operations SET cleanup_state = 'pending', updated_at_ms = 5"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "UPDATE cleanup_debts SET attempt_count = attempt_count + 1, updated_at_ms = 5"
        ))

        try connection.execute("BEGIN IMMEDIATE")
        do {
            try connection.execute("DELETE FROM cleanup_debts")
            #expect(throws: SQLiteStoreError.self) { try connection.execute("COMMIT") }
            try connection.execute("ROLLBACK")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }

        let reopened = try SkillSchemaMigrator.open(at: location.database, accessMode: .readOnly)
        #expect(try reopened.querySingleText(
            "SELECT cleanup_state FROM skill_operations"
        ) == "needsRepair")
        #expect(try reopened.querySingleInt("SELECT count(*) FROM cleanup_debts") == 1)
    }

    @Test("canonical schema rejects cleanup repair constraint drift")
    func rejectsWeakenedCleanupRepairDDL() throws {
        let location = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        try createStructurallyDriftedV2(
            at: location.database,
            transformV1SQL: { _, sql in sql },
            transformV2SQL: { index, sql in
                guard index == 1 else { return sql }
                return sql.replacingOccurrences(
                    of: "'notApplicable', 'notStarted', 'pending', 'completed', 'needsRepair'",
                    with: "'notApplicable', 'notStarted', 'pending', 'completed'"
                )
            }
        )
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: location.database)
        }
    }

    @Test("database-committed repair remains a blocker after reopen")
    func persistsDatabaseCommittedRepairBlocker() throws {
        let location = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let operationID = SSOTOperationID(
            UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!
        )
        let debtID = SSOTCleanupDebtID(
            UUID(uuidString: "bbbbbbbb-2222-4333-8444-cccccccccccc")!
        )

        do {
            let connection = try SkillSchemaMigrator.open(at: location.database)
            try prepareDatabaseCommittedPendingDebt(
                connection: connection,
                domainPayload: v2Blob(try cleanupRepairPayload())
            )
            let store = try SSOTJournalStore(connection: connection)
            try store.markNeedsRepair(
                operationID: operationID,
                errorCode: .replaceStateMismatch,
                detail: "cleanup removed before terminal update",
                updatedAtMilliseconds: 4
            )

            let operation = try store.loadOperation(operationID)
            let debt = try #require(try store.loadCleanupDebt(for: operation))
            #expect(operation.state == .init(
                phase: .databaseCommitted,
                outcome: .needsRepair,
                cleanupState: .pending
            ))
            #expect(debt.debtID == debtID)
            #expect(try store.cleanupDebtObservation(for: operation) == .verifiedRecovery)
            #expect(try store.recoverableOperationIDs().isEmpty)
            #expect(try store.recoverableOperations().isEmpty)
            #expect(try store.repairRequiredOperations().map(\.operationID) == [operationID])
            #expect(try store.firstRepairRequiredOperation()?.operationID == operationID)

            #expect(throws: SSOTJournalStoreError.stateConflict) {
                try store.completeCleanupDebt(
                    operationID: operationID,
                    debtID: debtID,
                    updatedAtMilliseconds: 5
                )
            }
            #expect(throws: SSOTJournalStoreError.stateConflict) {
                try store.recordCleanupDebtFailure(
                    operationID: operationID,
                    debtID: debtID,
                    errorCode: "retry",
                    updatedAtMilliseconds: 5
                )
            }
            #expect(try store.loadCleanupDebt(for: operation)?.attemptCount == debt.attemptCount)
        }

        let reopened = try SSOTJournalStore(
            connection: SkillSchemaMigrator.open(at: location.database)
        )
        let operation = try reopened.loadOperation(operationID)
        #expect(operation.state.outcome == .needsRepair)
        #expect(operation.state.cleanupState == .pending)
        #expect(try reopened.loadCleanupDebt(for: operation)?.debtID == debtID)
        #expect(try reopened.recoverableOperationIDs().isEmpty)
        #expect(try reopened.repairRequiredOperations().map(\.operationID) == [operationID])
        #expect(try reopened.firstRepairRequiredOperation()?.operationID == operationID)
    }

    @Test(
        "database-committed repair validates exact cleanup debt ownership",
        arguments: CleanupDebtDrift.allCases
    )
    func rejectsDatabaseCommittedRepairDebtDrift(_ drift: CleanupDebtDrift) throws {
        let location = try v2DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        do {
            let connection = try SkillSchemaMigrator.open(at: location.database)
            try prepareDatabaseCommittedPendingDebt(connection: connection)
            try connection.execute(
                "UPDATE skill_operations SET outcome = 'needsRepair', updated_at_ms = 4"
            )
            let immutableTrigger = try #require(SkillSchemaV2.statements.first {
                $0.contains("CREATE TRIGGER cleanup_debts_immutable_ownership")
            })
            try connection.execute("DROP TRIGGER cleanup_debts_immutable_ownership")
            try connection.execute(drift.updateSQL)
            try connection.execute(immutableTrigger)
        }

        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: location.database)
        }
    }
}

private func preparePendingDebt(
    _ outcome: SkillSchemaV2CleanupRepairTests.TerminalOutcome,
    connection: SQLiteConnection
) throws {
    switch outcome {
    case .rolledBack:
        try connection.execute(createOperationInsert())
        try connection.execute("BEGIN IMMEDIATE")
        try connection.execute(rolledBackPendingUpdate())
        try connection.execute(cleanupDebtInsert())
        try connection.execute("COMMIT")
    case .applied:
        try prepareDatabaseCommittedPendingDebt(connection: connection)
        #expect(v2SQLIsRejected(
            connection,
            "UPDATE skill_operations SET outcome = 'needsRepair', "
                + "cleanup_state = 'needsRepair', updated_at_ms = 3"
        ))
        try connection.execute(
            "UPDATE skill_operations SET phase = 'completed', outcome = 'applied', updated_at_ms = 3"
        )
    }
}

private func prepareDatabaseCommittedPendingDebt(
    connection: SQLiteConnection,
    domainPayload: String = "X'7b7d'"
) throws {
    try connection.execute(replaceOperationInsert(domainPayload: domainPayload))
    try connection.execute(
        "UPDATE skill_operations SET phase = 'filesystemApplied', updated_at_ms = 1"
    )
    try connection.execute(
        "UPDATE skill_operations SET phase = 'databaseCommitted', updated_at_ms = 2"
    )
    try connection.execute("BEGIN IMMEDIATE")
    do {
        try connection.execute(
            "UPDATE skill_operations SET cleanup_state = 'pending', "
                + "cleanup_debt_id = \(v2Blob(v2DebtA)), updated_at_ms = 3"
        )
        try connection.execute(recoveryCleanupDebtInsert())
        try connection.execute("COMMIT")
    } catch {
        try? connection.execute("ROLLBACK")
        throw error
    }
}

private func cleanupRepairPayload() throws -> Data {
    let skill = try ManagedSkillRecord(
        skillID: SkillID(UUID(uuidString: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")!),
        displayName: SkillDisplayName("Demo"),
        defaultDistributionSlug: DefaultDistributionSlug(validating: "demo"),
        contentFingerprint: SkillContentFingerprint(
            algorithmVersion: 1,
            digest: Data(repeating: 0xab, count: 32)
        ),
        createdAtMilliseconds: 0,
        updatedAtMilliseconds: 0
    )
    return try SSOTWritePayloadCodec.encode(SSOTSkillWritePayload(skill: skill))
}
