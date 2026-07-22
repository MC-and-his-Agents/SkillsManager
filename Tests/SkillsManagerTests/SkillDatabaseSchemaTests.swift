import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema migration")
struct SkillDatabaseSchemaTests {
    @Test("creates the current schema outside the WAL transition and reopens it")
    func createsAndReopensCurrentSchema() throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        do {
            let connection = try SkillSchemaMigrator.open(at: location.database)
            #expect(try connection.querySingleText("PRAGMA journal_mode")?.lowercased() == "wal")
            #expect(try connection.querySingleInt("PRAGMA foreign_keys") == 1)
            #expect(try connection.querySingleInt("PRAGMA busy_timeout") == 5_000)
            #expect(try connection.querySingleInt("PRAGMA synchronous") == 2)
            #expect(try connection.querySingleInt("PRAGMA user_version") == 2)
            #expect(try connection.userTableNames() == SkillSchemaV2.tableNames)

            let strictCount = try connection.querySingleInt(
                "SELECT count(*) FROM pragma_table_list "
                    + "WHERE name IN ('schema_metadata','skills','sources','provider_aliases',"
                    + "'skill_operations','cleanup_debts') "
                    + "AND strict = 1"
            )
            #expect(strictCount == 6)
        }

        let reopened = try SkillSchemaMigrator.open(at: location.database)
        #expect(try reopened.querySingleInt("PRAGMA user_version") == 2)
        #expect(try reopened.querySingleInt(
            "SELECT schema_version FROM schema_metadata WHERE singleton = 1"
        ) == 2)
    }

    @Test("rolls v0 back when the v1 stage fails")
    func rollsBackMigration() throws {
        enum InjectedFailure: Error { case stop }
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        #expect(throws: InjectedFailure.self) {
            _ = try SkillSchemaMigrator.open(at: location.database, beforeCommit: {
                throw InjectedFailure.stop
            })
        }

        let connection = try SQLiteConnection(url: location.database)
        #expect(try connection.querySingleInt("PRAGMA user_version") == 0)
        #expect(try connection.userTableNames().isEmpty)
    }

    @Test("rolls v0 back when the v2 stage fails and later migrates successfully")
    func rollsV0BackWhenV2StageFails() throws {
        enum InjectedFailure: Error { case stop }
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        #expect(throws: InjectedFailure.self) {
            _ = try SkillSchemaMigrator.open(at: location.database, beforeV2Commit: {
                throw InjectedFailure.stop
            })
        }

        let rolledBack = try SQLiteConnection(url: location.database)
        #expect(try rolledBack.querySingleInt("PRAGMA user_version") == 0)
        #expect(try rolledBack.userTableNames().isEmpty)

        let migrated = try SkillSchemaMigrator.open(at: location.database)
        #expect(try migrated.querySingleInt("PRAGMA user_version") == 2)
        #expect(try migrated.userTableNames() == SkillSchemaV2.tableNames)
    }

    @Test("rechecks v0 after obtaining the migration write lock")
    func handlesAConcurrentV0Migration() throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let first = try SQLiteConnection(url: location.database)
        let second = try SQLiteConnection(url: location.database)
        try first.setJournalModeWAL()
        try second.setJournalModeWAL()
        var checkpointRan = false

        try SkillSchemaMigrator.migrateIfNeeded(second, afterInitialV0Read: {
            checkpointRan = true
            try SkillSchemaMigrator.migrateIfNeeded(first)
        })

        #expect(checkpointRan)
        #expect(try first.querySingleInt("PRAGMA user_version") == 2)
        #expect(try second.querySingleInt("PRAGMA user_version") == 2)
        #expect(try second.userTableNames() == SkillSchemaV2.tableNames)
    }

    @Test("clears bindings even when reset reports a failed step")
    func reusesStatementAfterFailedStep() throws {
        let location = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let connection = try SQLiteConnection(url: location.database)
        try connection.execute(
            "CREATE TABLE reset_test(first TEXT UNIQUE, second TEXT) STRICT"
        )
        let statement = try connection.prepare(
            "INSERT INTO reset_test(first, second) VALUES (?, ?)"
        )

        try statement.bind("same", at: 1)
        try statement.bind("initial", at: 2)
        #expect(try !statement.step())
        try statement.reset()

        try statement.bind("same", at: 1)
        try statement.bind("must-be-cleared", at: 2)
        #expect(throws: SQLiteStoreError.self) {
            _ = try statement.step()
        }
        #expect(throws: SQLiteStoreError.self) {
            try statement.reset()
        }

        try statement.bind("other", at: 1)
        #expect(try !statement.step())
        #expect(try connection.querySingleInt(
            "SELECT second IS NULL FROM reset_test WHERE first = 'other'"
        ) == 1)
    }

    @Test("rejects negative, future, unknown, and mismatched schemas")
    func rejectsInvalidSchemaStates() throws {
        let negative = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: negative.root) }
        try SQLiteConnection(url: negative.database).execute("PRAGMA user_version = -1")
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: negative.database)
        }

        let unknown = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: unknown.root) }
        try SQLiteConnection(url: unknown.database).execute("CREATE TABLE unexpected(value TEXT) STRICT")
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: unknown.database)
        }

        let future = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: future.root) }
        let futureConnection = try SkillSchemaMigrator.open(at: future.database)
        try futureConnection.execute("PRAGMA user_version = 3")
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: future.database)
        }

        let mismatch = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: mismatch.root) }
        let mismatchConnection = try SkillSchemaMigrator.open(at: mismatch.database)
        try mismatchConnection.execute("UPDATE schema_metadata SET schema_version = 3")
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: mismatch.database)
        }
    }

    @Test("rejects missing, extra, and multiple metadata rows")
    func rejectsMalformedV1Metadata() throws {
        let missing = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: missing.root) }
        let missingConnection = try SQLiteConnection(url: missing.database)
        try createNamedPlaceholderTables(missingConnection, metadataRows: [])
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: missing.database)
        }

        let multiple = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: multiple.root) }
        let multipleConnection = try SQLiteConnection(url: multiple.database)
        try createNamedPlaceholderTables(multipleConnection, metadataRows: [(1, 1), (2, 1)])
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: multiple.database)
        }

        let extra = try temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: extra.root) }
        let extraConnection = try SkillSchemaMigrator.open(at: extra.database)
        try extraConnection.execute("CREATE TABLE unexpected(value TEXT) STRICT")
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: extra.database)
        }
    }
}

private func temporaryDatabaseLocation() throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skillsmanager-schema-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("manager.sqlite"))
}

private func createNamedPlaceholderTables(
    _ connection: SQLiteConnection,
    metadataRows: [(Int, Int)]
) throws {
    try connection.execute("CREATE TABLE schema_metadata(singleton INTEGER, schema_version INTEGER) STRICT")
    try connection.execute("CREATE TABLE skills(value TEXT) STRICT")
    try connection.execute("CREATE TABLE sources(value TEXT) STRICT")
    try connection.execute("CREATE TABLE provider_aliases(value TEXT) STRICT")
    for row in metadataRows {
        try connection.execute(
            "INSERT INTO schema_metadata(singleton, schema_version) "
                + "VALUES (\(row.0), \(row.1))"
        )
    }
    try connection.execute("PRAGMA user_version = 1")
}
