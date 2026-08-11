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
    }

    @MainActor
    @Test("custom paths are read, inserted, and removed only in SQLite")
    func mutatesCustomPaths() throws {
        let fixture = try LegacyMigrationTestFixture(customPaths: legacyCustomPathsFixture)
        let connection = try admittedConnection(fixture)
        let persistence = try SQLiteCustomPathPersistence(connection: connection)
        let existing = try #require(try persistence.loadAll().first)
        #expect(existing.mode == .project)

        let added = CustomSkillPath(
            url: URL(fileURLWithPath: "/tmp/another", isDirectory: true),
            mode: .collection(adapter: .codex)
        )
        try persistence.insert(added)
        #expect(try persistence.loadAll().count == 2)
        #expect(try persistence.loadAll().last?.mode == .collection(adapter: .codex))
        try persistence.remove(id: added.id)
        #expect(try persistence.loadAll().count == 1)
        #expect(try String(
            contentsOf: fixture.legacyRoot.appendingPathComponent("custom-paths.json"),
            encoding: .utf8
        ) == legacyCustomPathsFixture)
    }

    @Test("custom path Codable round trips explicit mode and keeps old project shape")
    func customPathCodableRoundTrip() throws {
        let project = CustomSkillPath(url: URL(fileURLWithPath: "/tmp/project", isDirectory: true))
        let projectData = try JSONEncoder().encode(project)
        #expect(!String(decoding: projectData, as: UTF8.self).contains("mode"))
        #expect(try JSONDecoder().decode(CustomSkillPath.self, from: projectData).mode == .project)

        let collection = CustomSkillPath(
            url: URL(fileURLWithPath: "/tmp/.codex/skills", isDirectory: true),
            mode: .collection(adapter: .codex)
        )
        let decoded = try JSONDecoder().decode(
            CustomSkillPath.self,
            from: JSONEncoder().encode(collection)
        )
        #expect(decoded.mode == .collection(adapter: .codex))
    }

    @MainActor
    @Test("every custom path operation rechecks the completed ledger")
    func rechecksLedgerForEveryOperation() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try admittedConnection(fixture)
        let customPaths = try SQLiteCustomPathPersistence(connection: connection)
        try connection.execute("DROP TRIGGER legacy_migration_ledger_no_delete")
        try connection.execute("DELETE FROM legacy_migration_ledger")

        #expect(throws: LegacyMigrationFailure.self) { _ = try customPaths.loadAll() }
        #expect(throws: LegacyMigrationFailure.self) {
            try customPaths.insert(CustomSkillPath(
                url: URL(fileURLWithPath: "/tmp/rejected", isDirectory: true)
            ))
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

    @Test("completed ledger rejects historical publish row drift")
    func rejectsPublishStateDrift() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let connection = try admittedConnection(fixture)
        try connection.execute("DELETE FROM publish_states")

        do {
            _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
            Issue.record("Expected ledger conflict")
        } catch let failure as LegacyMigrationFailure {
            #expect(failure.code == .ledgerConflict)
            #expect(!failure.retryable)
        }
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
    @Test("completed ledger and historical publish rows remain readable after reopen")
    func reopensOnSQLiteTruth() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
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
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(reopened)
        #expect(try reopened.querySingleInt("SELECT count(*) FROM publish_states") == 1)
        #expect(try reopened.querySingleText(
            "SELECT last_published_hash FROM publish_states"
        ) == "abc123")
    }
}
