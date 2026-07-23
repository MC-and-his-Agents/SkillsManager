import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Legacy state migration")
struct LegacyStateMigrationTests {
    @Test("migrates custom paths and publish state with one completed ledger")
    func migratesAllState() throws {
        let fixture = try LegacyMigrationTestFixture(
            customPaths: legacyCustomPathsFixture,
            publishStates: ["demo": legacyPublishFixture]
        )
        let connection = try fixture.connection()
        let result = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: { 42 }
        )

        #expect(!result.archiveChanged)
        #expect(try connection.querySingleInt("SELECT count(*) FROM custom_paths") == 1)
        #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_publish_states") == 1)
        #expect(try connection.querySingleInt("SELECT count(*) FROM publish_states") == 1)
        #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_migration_ledger") == 1)
        #expect(try connection.querySingleText(
            "SELECT source_legacy_locator FROM publish_states"
        ) == "skill-state/demo.json")
    }

    @Test("invalid legacy JSON leaves the database without partial migration truth")
    func rollsBackInvalidState() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: [
            "valid": legacyPublishFixture,
            "broken": "{not-json}",
        ])
        let connection = try fixture.connection()
        #expect(throws: LegacyMigrationFailure.self) {
            _ = try LegacyStateMigrationGate.migrateIfNeeded(
                homeURL: fixture.home,
                connection: connection,
                ownership: fixture.ownership
            )
        }
        #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_migration_ledger") == 0)
        #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_publish_states") == 0)
        #expect(try connection.querySingleInt("SELECT count(*) FROM publish_states") == 0)
    }

    @Test("completed ledger is idempotent and later archive changes are diagnostic only")
    func completedLedgerWins() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let connection = try fixture.connection()
        _ = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: { 42 }
        )
        try fixture.writePublish(
            "demo",
            json: "{\"lastPublishedHash\":\"changed\",\"lastPublishedAt\":1,\"hashAlgorithmVersion\":1}"
        )
        let result = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: { 99 }
        )
        #expect(result.archiveChanged)
        #expect(try connection.querySingleText(
            "SELECT last_published_hash FROM legacy_publish_states"
        ) == "abc123")
        #expect(try connection.querySingleInt(
            "SELECT completed_at_ms FROM legacy_migration_ledger"
        ) == 42)
    }

    @Test("completed ledger makes archive capture failures non-blocking")
    func completedLedgerAllowsUnavailableArchive() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let connection = try fixture.connection()
        _ = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: { 42 }
        )

        let moved = fixture.root.appendingPathComponent("legacy-archive", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.legacyRoot, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.legacyRoot, withDestinationURL: moved)

        let result = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership
        )
        #expect(result.diagnostics == [
            LegacyMigrationDiagnostic(code: .legacyArchiveChanged, locator: nil),
        ])
        _ = try SQLitePublishStatePersistence(connection: connection)
    }

    @Test("completed ledger ignores later diagnostic capture limits")
    func completedLedgerAllowsDiagnosticLimitFailure() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let connection = try fixture.connection()
        _ = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: { 42 }
        )
        let result = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            maximumTotalBytes: 0
        )
        #expect(result.archiveChanged)
        _ = try SQLiteCustomPathPersistence(connection: connection)
    }

    @Test("completed ledger makes later archive permission drift non-blocking")
    func completedLedgerAllowsArchivePermissionDrift() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let connection = try fixture.connection()
        _ = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: { 42 }
        )
        guard Darwin.chmod(fixture.legacyRoot.path, 0o777) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { _ = Darwin.chmod(fixture.legacyRoot.path, 0o700) }
        let result = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership
        )
        #expect(result.archiveChanged)
        _ = try SQLitePublishStatePersistence(connection: connection)
    }

    @Test("completed ledger still fails closed when writer ownership drifts")
    func completedLedgerRejectsOwnershipDrift() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try fixture.connection()
        _ = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: { 42 }
        )
        let managementRoot = fixture.database.deletingLastPathComponent()
        defer { _ = Darwin.chmod(managementRoot.path, 0o700) }
        do {
            _ = try LegacyStateMigrationGate.migrateIfNeeded(
                homeURL: fixture.home,
                connection: connection,
                ownership: fixture.ownership,
                afterCompletedLedgerRead: {
                    guard Darwin.chmod(managementRoot.path, 0o777) == 0 else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                }
            )
            Issue.record("Expected ownership drift rejection")
        } catch let failure as LegacyMigrationFailure {
            #expect(failure.code == .ownershipUnavailable)
        }
    }

    @Test("migration timestamp uses the shared date codec")
    func migrationTimestampCodec() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try fixture.connection()
        _ = try LegacyStateMigrationGate.migrateIfNeeded(
            homeURL: fixture.home,
            connection: connection,
            ownership: fixture.ownership,
            nowMilliseconds: {
                try LegacyDateCodec.milliseconds(from: Date(timeIntervalSince1970: 1.2346))
            }
        )
        #expect(try connection.querySingleInt(
            "SELECT completed_at_ms FROM legacy_migration_ledger"
        ) == 1_235)
    }

    @Test("failure after ledger staging rolls back every migration row")
    func preCommitFailureRollsBack() throws {
        enum InjectedFailure: Error { case stop }
        let fixture = try LegacyMigrationTestFixture(
            customPaths: legacyCustomPathsFixture,
            publishStates: ["demo": legacyPublishFixture]
        )
        let connection = try fixture.connection()
        do {
            _ = try LegacyStateMigrationExecutor.migrate(
                inventory: fixture.inventory(),
                connection: connection,
                ownership: fixture.ownership,
                beforeCommit: { throw InjectedFailure.stop }
            )
            Issue.record("Expected injected migration failure")
        } catch let failure as LegacyMigrationFailure {
            #expect(failure.code == .databaseFailure)
        }
        #expect(try connection.querySingleInt("SELECT count(*) FROM custom_paths") == 0)
        #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_publish_states") == 0)
        #expect(try connection.querySingleInt("SELECT count(*) FROM publish_states") == 0)
        #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_migration_ledger") == 0)
    }
}

@Suite("Legacy state migration races")
struct LegacyStateMigrationRaceTests {
    @Test("archive replacement before commit rolls back the whole transaction")
    func replacementRollsBack() throws {
        let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let inventory = try fixture.inventory()
        try fixture.writePublish(
            "demo",
            json: "{\"lastPublishedHash\":\"raced\",\"lastPublishedAt\":1,\"hashAlgorithmVersion\":1}"
        )
        let connection = try fixture.connection()
        #expect(throws: LegacyMigrationFailure.self) {
            _ = try LegacyStateMigrationExecutor.migrate(
                inventory: inventory,
                connection: connection,
                ownership: fixture.ownership
            )
        }
        #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_migration_ledger") == 0)
        #expect(try connection.querySingleInt("SELECT count(*) FROM publish_states") == 0)
    }

    @Test("file additions and deletions before commit roll back")
    func fileSetChangesRollBack() throws {
        let added = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let addedInventory = try added.inventory()
        let addedConnection = try added.connection()
        try added.writePublish("new", json: legacyPublishFixture)
        try assertMigrationRollsBack(
            fixture: added,
            inventory: addedInventory,
            connection: addedConnection
        )

        let deleted = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let deletedInventory = try deleted.inventory()
        let deletedConnection = try deleted.connection()
        try FileManager.default.removeItem(at: deleted.publishURL("demo"))
        try assertMigrationRollsBack(
            fixture: deleted,
            inventory: deletedInventory,
            connection: deletedConnection
        )
    }

    @Test("same-inode edits and symlink replacement before commit roll back")
    func contentAndTypeChangesRollBack() throws {
        let edited = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let editedInventory = try edited.inventory()
        let editedConnection = try edited.connection()
        try edited.rewritePublishInPlace(
            "demo",
            json: legacyPublishFixture.replacingOccurrences(of: "abc123", with: "xyz789")
        )
        try assertMigrationRollsBack(
            fixture: edited,
            inventory: editedInventory,
            connection: editedConnection
        )

        let linked = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
        let linkedInventory = try linked.inventory()
        let linkedConnection = try linked.connection()
        let original = linked.publishURL("demo")
        let moved = linked.root.appendingPathComponent("moved-demo.json")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        try assertMigrationRollsBack(
            fixture: linked,
            inventory: linkedInventory,
            connection: linkedConnection
        )
    }

    @Test("every anchored directory binding rejects replacement")
    func directoryReplacementRollsBack() throws {
        for index in 0..<5 {
            let fixture = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
            let inventory = try fixture.inventory()
            let connection = try fixture.connection()
            let target = fixture.legacyDirectoryChain[index]
            let moved = target.deletingLastPathComponent()
                .appendingPathComponent("moved-\(index)", isDirectory: true)
            try FileManager.default.moveItem(at: target, to: moved)
            try createOwnerOnlyDirectory(target)
            try assertMigrationRollsBack(
                fixture: fixture,
                inventory: inventory,
                connection: connection
            )
        }
    }

    @Test("every anchored directory rejects symlink and writable-mode replacement")
    func directoryTypeAndPermissionChangesRollBack() throws {
        for index in 0..<5 {
            let linked = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
            let linkedInventory = try linked.inventory()
            let linkedConnection = try linked.connection()
            let target = linked.legacyDirectoryChain[index]
            let moved = target.deletingLastPathComponent()
                .appendingPathComponent("linked-\(index)", isDirectory: true)
            try FileManager.default.moveItem(at: target, to: moved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
            try assertMigrationRollsBack(
                fixture: linked,
                inventory: linkedInventory,
                connection: linkedConnection
            )

            let writable = try LegacyMigrationTestFixture(publishStates: ["demo": legacyPublishFixture])
            let writableInventory = try writable.inventory()
            let writableConnection = try writable.connection()
            guard Darwin.chmod(writable.legacyDirectoryChain[index].path, 0o777) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try assertMigrationRollsBack(
                fixture: writable,
                inventory: writableInventory,
                connection: writableConnection
            )
        }
    }
}

private func assertMigrationRollsBack(
    fixture: LegacyMigrationTestFixture,
    inventory: LegacyStateInventory,
    connection: SQLiteConnection
) throws {
    do {
        _ = try LegacyStateMigrationExecutor.migrate(
            inventory: inventory,
            connection: connection,
            ownership: fixture.ownership
        )
        Issue.record("Expected migration race rejection")
    } catch let failure as LegacyMigrationFailure {
        #expect(failure.retryable)
    }
    #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_migration_ledger") == 0)
    #expect(try connection.querySingleInt("SELECT count(*) FROM legacy_publish_states") == 0)
    #expect(try connection.querySingleInt("SELECT count(*) FROM publish_states") == 0)
}
