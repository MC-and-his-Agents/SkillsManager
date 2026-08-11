import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v16", .serialized)
struct SkillSchemaV16Tests {
    enum InjectedFailure: Error { case stop }

    @Test("migrates v14 atomically and admits read-only")
    func migration() throws {
        try withRawV14Database { connection, url in
            try connection.execute(
                "INSERT INTO custom_paths VALUES "
                    + "(X'00112233445566778899aabbccddeeff', "
                    + "'file:///tmp/legacy/', X'2f746d702f6c6567616379', 'Legacy', 1)"
            )
            #expect(throws: InjectedFailure.stop) {
                try SkillSchemaMigrator.migrateIfNeeded(
                    connection,
                    beforeV15Commit: { throw InjectedFailure.stop }
                )
            }
            #expect(try connection.querySingleInt("PRAGMA user_version") == 14)
            #expect(try !connection.userTableNames().contains("repository_catalog"))

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            #expect(try connection.querySingleInt("PRAGMA user_version") == 16)
            #expect(try connection.querySingleText(
                "SELECT root_mode FROM custom_paths WHERE display_name = 'Legacy'"
            ) == "project")
            #expect(try connection.querySingleText(
                "SELECT adapter_code FROM custom_paths WHERE display_name = 'Legacy'"
            ) == nil)
            _ = try SkillSchemaMigrator.open(at: url, accessMode: .readOnly)
        }
    }

    @Test("read-only rejects fingerprint changes")
    func fingerprint() throws {
        try withV15DatabaseURL { url in
            let connection = try SkillSchemaMigrator.open(at: url)
            try connection.execute("ALTER TABLE repository_catalog ADD COLUMN extra TEXT")
            #expect(throws: SQLiteStoreError.self) {
                try SkillSchemaMigrator.open(at: url, accessMode: .readOnly)
            }
        }
    }

    @Test("v16 checkpoint rolls back the legacy custom path rewrite")
    func v16CheckpointRollsBack() throws {
        try withRawV14Database { connection, _ in
            #expect(throws: InjectedFailure.stop) {
                try SkillSchemaMigrator.migrateIfNeeded(
                    connection,
                    beforeV16Commit: { throw InjectedFailure.stop }
                )
            }
            let version = try connection.querySingleInt("PRAGMA user_version")
            let tableNames = try connection.userTableNames()
            let customPathColumns = try SkillSchemaInspection.columnNames(
                connection,
                table: "custom_paths"
            )
            #expect(version == 14)
            #expect(!tableNames.contains("repository_catalog"))
            #expect(customPathColumns == [
                "custom_path_id", "absolute_url", "normalized_url_key", "display_name",
                "added_at_ms",
            ])
        }
    }
}

private func withRawV14Database(
    _ body: (SQLiteConnection, URL) throws -> Void
) throws {
    try withV15DatabaseURL { url in
        let connection = try SkillSchemaMigrator.open(at: url)
        try connection.execute("DROP TRIGGER custom_paths_id_immutable")
        try connection.execute("DROP TABLE custom_paths")
        try connection.execute(SkillSchemaV3.statements[0])
        try connection.execute(
            SkillSchemaV3.statements.first {
                $0.contains("CREATE TRIGGER custom_paths_id_immutable")
            }!
        )
        try connection.execute("DROP TABLE repository_catalog")
        try connection.execute("UPDATE schema_metadata SET schema_version = 14 WHERE singleton = 1")
        try connection.execute("PRAGMA user_version = 14")
        try SkillSchemaMigrator.validateV14(connection)
        try body(connection, url)
    }
}

private func withV15DatabaseURL(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v15-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root.appendingPathComponent("manager.sqlite"))
}
