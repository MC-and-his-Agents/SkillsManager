import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v15", .serialized)
struct SkillSchemaV15Tests {
    enum InjectedFailure: Error { case stop }

    @Test("migrates v14 atomically and admits read-only")
    func migration() throws {
        try withRawV14Database { connection, url in
            #expect(throws: InjectedFailure.stop) {
                try SkillSchemaMigrator.migrateIfNeeded(
                    connection,
                    beforeV15Commit: { throw InjectedFailure.stop }
                )
            }
            #expect(try connection.querySingleInt("PRAGMA user_version") == 14)
            #expect(try !connection.userTableNames().contains("repository_catalog"))

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            #expect(try connection.querySingleInt("PRAGMA user_version") == 15)
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
}

private func withRawV14Database(
    _ body: (SQLiteConnection, URL) throws -> Void
) throws {
    try withV15DatabaseURL { url in
        let connection = try SkillSchemaMigrator.open(at: url)
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
