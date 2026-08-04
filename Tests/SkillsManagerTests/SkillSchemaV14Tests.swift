import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v14", .serialized)
struct SkillSchemaV14Tests {
    enum InjectedFailure: Error { case stop }

    @Test("migrates v13 atomically and reopens read-only")
    func migratesV13() throws {
        try withRawV13Database { connection, databaseURL in
            #expect(throws: InjectedFailure.stop) {
                try SkillSchemaMigrator.migrateIfNeeded(
                    connection,
                    beforeV14Commit: { throw InjectedFailure.stop }
                )
            }
            #expect(try connection.querySingleInt("PRAGMA user_version") == 13)
            #expect(try connection.userTableNames().contains("skill_update_checks") == false)

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            #expect(try connection.querySingleInt("PRAGMA user_version") == 15)
            #expect(try connection.querySingleInt("SELECT count(*) FROM skill_update_checks") == 0)

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            let reader = try SkillSchemaMigrator.open(at: databaseURL, accessMode: .readOnly)
            #expect(reader.accessMode == .readOnly)
        }
    }

    @Test("read-only admission rejects a changed v14 schema")
    func rejectsChangedSchema() throws {
        try withV14DatabaseURL { databaseURL in
            let connection = try SkillSchemaMigrator.open(at: databaseURL)
            try connection.execute("DROP TABLE skill_update_checks")
            try connection.execute(
                """
                CREATE TABLE skill_update_checks (
                  skill_id BLOB PRIMARY KEY NOT NULL
                    REFERENCES skills(skill_id) ON DELETE CASCADE,
                  format_version INTEGER NOT NULL CHECK (format_version = 1),
                  status TEXT NOT NULL,
                  checked_at_ms INTEGER NOT NULL CHECK (checked_at_ms >= 0),
                  snapshot_payload BLOB NOT NULL
                    CHECK (length(snapshot_payload) BETWEEN 1 AND 65536)
                ) STRICT
                """
            )
            #expect(throws: SQLiteStoreError.self) {
                try SkillSchemaMigrator.open(at: databaseURL, accessMode: .readOnly)
            }
        }
    }
}

private func withRawV13Database(
    _ body: (SQLiteConnection, URL) throws -> Void
) throws {
    try withV14DatabaseURL { databaseURL in
        let connection = try SkillSchemaMigrator.open(at: databaseURL)
        try connection.execute("DROP TABLE repository_catalog")
        try connection.execute("DROP TABLE skill_update_checks")
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 13 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 13")
        try SkillSchemaMigrator.validateV13(connection)
        try body(connection, databaseURL)
    }
}

private func withV14DatabaseURL(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v14-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root.appendingPathComponent("manager.sqlite"))
}
