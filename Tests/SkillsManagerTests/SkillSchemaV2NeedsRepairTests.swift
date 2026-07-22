import Testing

@testable import SkillsManager

@Suite("Skill database schema v2 needs-repair states")
struct SkillSchemaV2NeedsRepairTests {
    enum RepairFixture: CaseIterable, Sendable {
        case createPrepared
        case createFilesystemApplied
        case createDatabaseCommitted
        case replacePrepared
        case replaceFilesystemApplied
        case replaceDatabaseCommitted
    }

    @Test(
        "nonterminal repair preserves phase-specific cleanup state",
        arguments: RepairFixture.allCases
    )
    func repairPreservesCleanupState(_ fixture: RepairFixture) throws {
        try withV2Database { connection in
            let expected = try prepare(fixture, connection: connection)
            #expect(v2SQLIsRejected(connection, "UPDATE skill_operations SET "
                + "outcome = 'needsRepair', cleanup_state = 'completed', updated_at_ms = 3"))
            try connection.execute(
                "UPDATE skill_operations SET outcome = 'needsRepair', updated_at_ms = 3"
            )
            #expect(try connection.querySingleText(
                "SELECT phase || ':' || outcome || ':' || cleanup_state FROM skill_operations"
            ) == expected)
        }
    }

    @Test("database-committed repair accepts its complete recovery debt")
    func databaseCommittedRepairKeepsRecoveryDebt() throws {
        try withV2Database { connection in
            try advanceReplacementToDatabaseCommitted(connection)
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
            try connection.execute("UPDATE skill_operations SET outcome = 'needsRepair', "
                + "attempt_count = 2, last_error = 'cleanup identity drift', updated_at_ms = 4")
            #expect(try connection.querySingleText("SELECT phase || ':' || outcome || ':' "
                + "|| cleanup_state FROM skill_operations") == "databaseCommitted:needsRepair:pending")
            #expect(try connection.querySingleInt("SELECT count(*) FROM cleanup_debts") == 1)
        }
    }

    private func advanceReplacementToDatabaseCommitted(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(replaceOperationInsert())
        try connection.execute(
            "UPDATE skill_operations SET phase = 'filesystemApplied', updated_at_ms = 1"
        )
        try connection.execute(
            "UPDATE skill_operations SET phase = 'databaseCommitted', updated_at_ms = 2"
        )
    }

    private func prepare(
        _ fixture: RepairFixture,
        connection: SQLiteConnection
    ) throws -> String {
        let isCreate = switch fixture {
        case .createPrepared, .createFilesystemApplied, .createDatabaseCommitted: true
        default: false
        }
        try connection.execute(isCreate ? createOperationInsert() : replaceOperationInsert())
        let phase: SSOTJournalPhase = switch fixture {
        case .createPrepared, .replacePrepared: .prepared
        case .createFilesystemApplied, .replaceFilesystemApplied: .filesystemApplied
        case .createDatabaseCommitted, .replaceDatabaseCommitted: .databaseCommitted
        }
        if phase != .prepared {
            try connection.execute(
                "UPDATE skill_operations SET phase = 'filesystemApplied', updated_at_ms = 1"
            )
        }
        if phase == .databaseCommitted {
            try connection.execute(
                "UPDATE skill_operations SET phase = 'databaseCommitted', updated_at_ms = 2"
            )
        }
        return "\(phase.rawValue):needsRepair:\(isCreate ? "notApplicable" : "notStarted")"
    }
}
