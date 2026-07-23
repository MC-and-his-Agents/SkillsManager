import Foundation
import Testing

@testable import SkillsManager

@Suite("Legacy SQLite persistence")
struct LegacySQLitePersistenceTests {
    @Test("components reject access until the completed ledger exists")
    func requiresCompletedLedger() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try fixture.connection()
        #expect(throws: LegacyMigrationFailure.self) {
            _ = try SQLiteCustomPathPersistence(connection: connection)
        }
        #expect(throws: LegacyMigrationFailure.self) {
            _ = try SQLitePublishStatePersistence(connection: connection)
        }
    }

    @Test("fresh publish state can be created and updated without legacy JSON")
    func createsFreshPublishState() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try admittedConnection(fixture)
        let persistence = try SQLitePublishStatePersistence(connection: connection)
        #expect(try persistence.load(forSlug: "new-skill") == nil)

        try persistence.save(
            SQLitePublishState(
                lastPublishedHash: "first",
                lastPublishedAtMilliseconds: 1,
                hashAlgorithmVersion: 1
            ),
            forSlug: "new-skill"
        )
        try persistence.save(
            SQLitePublishState(
                lastPublishedHash: "second",
                lastPublishedAtMilliseconds: 2,
                hashAlgorithmVersion: 1
            ),
            forSlug: "new-skill"
        )
        #expect(try persistence.load(forSlug: "new-skill")?.lastPublishedHash == "second")
        #expect(try connection.querySingleInt(
            "SELECT source_legacy_locator IS NULL FROM publish_states"
        ) == 1)
        #expect(throws: LegacyMigrationFailure.self) {
            try persistence.save(
                SQLitePublishState(
                    lastPublishedHash: "invalid-legacy-algorithm",
                    lastPublishedAtMilliseconds: 3,
                    hashAlgorithmVersion: nil
                ),
                forSlug: "new-skill"
            )
        }
    }

    @Test("runtime publish updates preserve immutable migration provenance")
    func preservesPublishProvenance() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let legacyURL = fixture.publishURL("demo")
        let originalBytes = try Data(contentsOf: legacyURL)
        let originalMetadata = try legacyFileMetadata(legacyURL)
        let connection = try admittedConnection(fixture)
        let persistence = try SQLitePublishStatePersistence(connection: connection)
        let originalDigest = try legacyFileDigest(connection)
        try persistence.save(
            SQLitePublishState(
                lastPublishedHash: "runtime",
                lastPublishedAtMilliseconds: 9,
                hashAlgorithmVersion: 1
            ),
            forSlug: "demo"
        )

        #expect(try persistence.load(forSlug: "demo")?.lastPublishedHash == "runtime")
        #expect(try connection.querySingleText(
            "SELECT last_published_hash FROM legacy_publish_states"
        ) == "abc123")
        #expect(try legacyFileDigest(connection) == originalDigest)
        #expect(try Data(contentsOf: legacyURL) == originalBytes)
        #expect(try legacyFileMetadata(legacyURL) == originalMetadata)
    }

    @Test("custom paths are read, inserted, and removed only in SQLite")
    @MainActor
    func mutatesCustomPaths() throws {
        let fixture = try LegacyMigrationTestFixture(customPaths: legacyCustomPathsFixture)
        let connection = try admittedConnection(fixture)
        let persistence = try SQLiteCustomPathPersistence(connection: connection)
        #expect(try persistence.loadAll().count == 1)

        let added = CustomSkillPath(url: URL(fileURLWithPath: "/tmp/another", isDirectory: true))
        try persistence.insert(added)
        #expect(try persistence.loadAll().count == 2)
        try persistence.remove(id: added.id)
        #expect(try persistence.loadAll().count == 1)
        #expect(try String(
            contentsOf: fixture.legacyRoot.appendingPathComponent("custom-paths.json"),
            encoding: .utf8
        )
            == legacyCustomPathsFixture)
    }

    @Test("every component read and write rechecks the completed ledger")
    @MainActor
    func rechecksLedgerForEveryOperation() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try admittedConnection(fixture)
        let customPaths = try SQLiteCustomPathPersistence(connection: connection)
        let publishStates = try SQLitePublishStatePersistence(connection: connection)
        try connection.execute("DROP TRIGGER legacy_migration_ledger_no_delete")
        try connection.execute("DELETE FROM legacy_migration_ledger")

        #expect(throws: LegacyMigrationFailure.self) { _ = try customPaths.loadAll() }
        #expect(throws: LegacyMigrationFailure.self) {
            try customPaths.insert(CustomSkillPath(
                url: URL(fileURLWithPath: "/tmp/rejected", isDirectory: true)
            ))
        }
        #expect(throws: LegacyMigrationFailure.self) { _ = try publishStates.load(forSlug: "demo") }
        #expect(throws: LegacyMigrationFailure.self) {
            try publishStates.save(
                SQLitePublishState(
                    lastPublishedHash: "rejected",
                    lastPublishedAtMilliseconds: 1,
                    hashAlgorithmVersion: 1
                ),
                forSlug: "demo"
            )
        }
    }

    @Test("component rejects contradictory provenance counts")
    func rejectsLedgerConflict() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let connection = try admittedConnection(fixture)
        try connection.execute("DELETE FROM publish_states")
        do {
            _ = try SQLitePublishStatePersistence(connection: connection)
            Issue.record("Expected ledger conflict")
        } catch let failure as LegacyMigrationFailure {
            #expect(failure.code == .ledgerConflict)
            #expect(!failure.retryable)
        }
    }

    @Test("custom path reader rejects URL and key drift")
    func rejectsCustomPathDrift() throws {
        let fixture = try LegacyMigrationTestFixture(customPaths: legacyCustomPathsFixture)
        let connection = try admittedConnection(fixture)
        let persistence = try SQLiteCustomPathPersistence(connection: connection)
        try connection.execute("UPDATE custom_paths SET absolute_url = 'file:///tmp/changed/'")
        do {
            _ = try persistence.loadAll()
            Issue.record("Expected custom path drift rejection")
        } catch let failure as LegacyMigrationFailure {
            #expect(failure.code == .ledgerConflict)
        }
    }

    private func legacyFileDigest(_ connection: SQLiteConnection) throws -> Data? {
        let statement = try connection.prepare("SELECT file_digest FROM legacy_publish_states")
        guard try statement.step() else { return nil }
        let digest = statement.blob(at: 0)
        guard try !statement.step() else {
            throw SQLiteStoreError.invalidState("legacy digest query returned more than one row")
        }
        return digest
    }

    private func legacyFileMetadata(_ url: URL) throws -> [FileAttributeKey: AnyHashable] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return [
            .posixPermissions: attributes[.posixPermissions] as? AnyHashable,
            .size: attributes[.size] as? AnyHashable,
            .modificationDate: attributes[.modificationDate] as? AnyHashable,
        ].compactMapValues { $0 }
    }

    private func admittedConnection(_ fixture: LegacyMigrationTestFixture) throws -> SQLiteConnection {
        let connection = try fixture.connection()
        _ = try LegacyStateMigrationExecutor.migrate(
            inventory: fixture.inventory(),
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: { 42 }
        )
        return connection
    }
}

@Suite("Legacy state cutover")
struct LegacyStateCutoverTests {
    @Test("completed ledger admits SQLite-only mutation after reopen")
    func reopensOnSQLiteTruth() throws {
        let fixture = try LegacyMigrationTestFixture()
        do {
            let connection = try fixture.connection()
            _ = try LegacyStateMigrationExecutor.migrate(
                inventory: fixture.inventory(),
                connection: connection,
                ownership: fixture.ownership,
                nowMilliseconds: { 42 }
            )
        }
        let reopened = try fixture.connection()
        let persistence = try SQLitePublishStatePersistence(connection: reopened)
        try persistence.save(
            SQLitePublishState(
                lastPublishedHash: "hash",
                lastPublishedAtMilliseconds: 1,
                hashAlgorithmVersion: 1
            ),
            forSlug: "demo"
        )
        #expect(try persistence.load(forSlug: "demo")?.lastPublishedHash == "hash")
    }
}
