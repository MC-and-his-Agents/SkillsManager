import Foundation
import Testing

@testable import SkillsManager

@Suite("SQLite access modes")
struct SQLiteAccessModeTests {
    @Test("read-only connections read back query_only and reject writes")
    func readOnlyIsEnforced() throws {
        let location = try accessModeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let writer = try SkillSchemaMigrator.open(at: location.database, accessMode: .readWrite)
        #expect(writer.accessMode == .readWrite)
        #expect(try writer.querySingleInt("PRAGMA query_only") == 0)

        let reader = try SkillSchemaMigrator.open(at: location.database, accessMode: .readOnly)
        #expect(reader.accessMode == .readOnly)
        #expect(try reader.querySingleInt("PRAGMA query_only") == 1)
        #expect(try reader.querySingleInt("PRAGMA user_version") == Int64(SkillSchemaV4.version))
        #expect(throws: SQLiteStoreError.self) {
            try reader.execute("DELETE FROM schema_metadata")
        }
        #expect(throws: SQLiteStoreError.self) {
            try SkillSchemaMigrator.migrateIfNeeded(reader)
        }
    }

    @Test("read-only access never creates a missing database")
    func readOnlyDoesNotCreate() throws {
        let location = try accessModeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        #expect(throws: SQLiteStoreError.self) {
            _ = try SQLiteConnection(url: location.database, accessMode: .readOnly)
        }
        #expect(!FileManager.default.fileExists(atPath: location.database.path))
    }

    @Test("all access modes reject database symlinks")
    func rejectsSymlink() throws {
        let location = try accessModeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let target = location.root.appendingPathComponent("target.sqlite")
        _ = try SkillSchemaMigrator.open(at: target)
        try FileManager.default.createSymbolicLink(
            at: location.database,
            withDestinationURL: target
        )

        for mode in [
            SQLiteAccessMode.readWrite,
            .readWriteExisting,
            .readOnly,
        ] {
            #expect(throws: SQLiteStoreError.self) {
                _ = try SQLiteConnection(url: location.database, accessMode: mode)
            }
        }
    }

    @Test("future schemas are rejected before journal mode can be changed")
    func futureSchemaDoesNotChangeJournalMode() throws {
        let location = try accessModeDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let originalMode: String
        do {
            let connection = try SQLiteConnection(url: location.database)
            let mode = try connection.querySingleText("PRAGMA journal_mode")
            originalMode = try #require(mode)
            try connection.execute("PRAGMA user_version = 5")
        }

        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(at: location.database, accessMode: .readWrite)
        }

        let reader = try SQLiteConnection(url: location.database, accessMode: .readOnly)
        #expect(try reader.querySingleText("PRAGMA journal_mode") == originalMode)
    }
}

private func accessModeDatabaseLocation() throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skillsmanager-access-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("manager.sqlite"))
}
