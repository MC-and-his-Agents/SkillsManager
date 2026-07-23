import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v4")
struct SkillSchemaV4Tests {
    @Test("migrates v3 to v4 atomically")
    func migratesV3Atomically() throws {
        enum InjectedFailure: Error { case stop }
        let location = try v4DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        do {
            let connection = try SkillSchemaMigrator.open(at: location.database)
            try removeV6ObjectsForLegacyFixture(connection)
            try connection.execute("DROP TABLE local_skill_origins")
            try connection.execute("DROP TABLE library_bootstrap")
            try connection.execute(
                "UPDATE schema_metadata SET schema_version = 3 WHERE singleton = 1"
            )
            try connection.execute("PRAGMA user_version = 3")
        }

        #expect(throws: InjectedFailure.self) {
            _ = try SkillSchemaMigrator.open(at: location.database, beforeV4Commit: {
                throw InjectedFailure.stop
            })
        }
        let rolledBack = try SQLiteConnection(url: location.database)
        #expect(try rolledBack.querySingleInt("PRAGMA user_version") == 3)
        #expect(try rolledBack.userTableNames() == SkillSchemaV3.tableNames)

        let migrated = try SkillSchemaMigrator.open(at: location.database)
        #expect(try migrated.querySingleInt("PRAGMA user_version") == 6)
        #expect(try migrated.userTableNames() == SkillSchemaV6.tableNames)
    }

    @Test("read-write-existing never creates a missing database")
    func readWriteExistingDoesNotCreate() throws {
        let location = try v4DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        #expect(throws: SQLiteStoreError.self) {
            _ = try SkillSchemaMigrator.open(
                at: location.database,
                accessMode: .readWriteExisting
            )
        }
        #expect(!FileManager.default.fileExists(atPath: location.database.path))
    }

    @Test("bootstrap identity is immutable while state may complete once")
    func bootstrapStateConstraints() throws {
        let location = try v4DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let identity = ManagedItemIdentityPersistedComponents(
            device: 1,
            inode: 2,
            fileType: UInt32(S_IFREG),
            generation: 3
        )
        let connection = try SkillSchemaMigrator.open(
            at: location.database,
            initializeV4: {
                try LibraryBootstrapStore.insertPrepared(
                    kind: .fresh,
                    bootstrapID: UUID(),
                    expectedMarkerIdentity: ManagedItemIdentity(persistedComponents: identity),
                    connection: $0
                )
            }
        )
        let loaded = try LibraryBootstrapStore.load(connection)
        let prepared = try #require(loaded)
        try connection.withImmediateTransaction {
            try LibraryBootstrapStore.complete(expected: prepared, connection: connection)
        }
        #expect(try LibraryBootstrapStore.load(connection)?.state == .completed)
        #expect(throws: SQLiteStoreError.self) {
            try connection.execute("DELETE FROM library_bootstrap")
        }
        #expect(throws: SQLiteStoreError.self) {
            try connection.execute("UPDATE library_bootstrap SET bootstrap_kind = 'legacy'")
        }
    }
}

private func v4DatabaseLocation() throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skillsmanager-v4-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("manager.sqlite"))
}
