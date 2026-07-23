import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v3")
struct SkillSchemaV3Tests {
    @Test("rolls the complete v0 to v3 schema transaction back on failure")
    func migratesV0Atomically() throws {
        enum InjectedFailure: Error { case stop }
        let fixture = try LegacyMigrationTestFixture()
        #expect(throws: InjectedFailure.self) {
            _ = try SkillSchemaMigrator.open(at: fixture.database, beforeV3Commit: {
                throw InjectedFailure.stop
            })
        }
        let rolledBack = try SQLiteConnection(url: fixture.database)
        #expect(try rolledBack.querySingleInt("PRAGMA user_version") == 0)
        #expect(try rolledBack.userTableNames().isEmpty)

        let migrated = try SkillSchemaMigrator.open(at: fixture.database)
        #expect(try migrated.querySingleInt("PRAGMA user_version") == 3)
        #expect(try migrated.userTableNames() == SkillSchemaV3.tableNames)
    }

    @Test("migrates v2 to v3 atomically")
    func migratesV2Atomically() throws {
        enum InjectedFailure: Error { case stop }
        let fixture = try LegacyMigrationTestFixture()
        try createStructurallyDriftedV2(at: fixture.database, transformV1SQL: { _, sql in sql })

        #expect(throws: InjectedFailure.self) {
            _ = try SkillSchemaMigrator.open(at: fixture.database, beforeV3Commit: {
                throw InjectedFailure.stop
            })
        }
        let rolledBack = try SQLiteConnection(url: fixture.database)
        #expect(try rolledBack.querySingleInt("PRAGMA user_version") == 2)
        #expect(try rolledBack.userTableNames() == SkillSchemaV2.tableNames)

        let migrated = try SkillSchemaMigrator.open(at: fixture.database)
        #expect(try migrated.querySingleInt("PRAGMA user_version") == 3)
        #expect(try migrated.userTableNames() == SkillSchemaV3.tableNames)
        #expect(try migrated.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE strict = 1 AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV3.tableNames.count))
    }

    @Test("enforces custom path identity and uniqueness")
    func enforcesCustomPathConstraints() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try fixture.connection()
        try connection.execute(
            "INSERT INTO custom_paths VALUES (X'\(v3CustomID)', 'file:///tmp/a/', X'2f746d702f61', 'A', 1)"
        )
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO custom_paths VALUES (X'00', 'file:///tmp/b/', X'2f746d702f62', 'B', 1)"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO custom_paths VALUES (X'\(v3SecondCustomID)', 'file:///tmp/a/', X'2f746d702f61', 'B', 1)"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "UPDATE custom_paths SET custom_path_id = X'\(v3SecondCustomID)'"
        ))
    }

    @Test("rejects invalid legacy provenance and runtime publish rows")
    func rejectsInvalidPublishRows() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try fixture.connection()
        #expect(v2SQLIsRejected(
            connection,
            """
            INSERT INTO legacy_publish_states VALUES (
              'skill-state/invalid.json', 0, X'00', 'hash', 1, 1,
              'unresolved', NULL, NULL, 1
            )
            """
        ))
        #expect(v2SQLIsRejected(
            connection,
            """
            INSERT INTO legacy_publish_states VALUES (
              'skill-state/invalid.json', 0, X'\(v3Digest)', 'hash', 1, 2,
              'unresolved', NULL, NULL, 1
            )
            """
        ))
        #expect(v2SQLIsRejected(
            connection,
            """
            INSERT INTO legacy_publish_states VALUES (
              'skill-state/invalid.json', 0, X'\(v3Digest)', 'hash', 1, 1,
              'bound', X'\(v3CustomID)', 1, 1
            )
            """
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO publish_states VALUES ('demo', NULL, 'x', 1, 1)"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO publish_states VALUES ('skill-state/nested/x.json', NULL, 'x', 1, 1)"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO publish_states VALUES ('skill-state/x.json', NULL, '', 1, 1)"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO publish_states VALUES ('skill-state/x.json', NULL, 'x', 1, 2)"
        ))
    }

    @Test("enforces immutable provenance, publish identity, and ledger")
    func enforcesMigrationImmutability() throws {
        let fixture = try LegacyMigrationTestFixture()
        let connection = try fixture.connection()
        try insertV3Provenance(connection)
        #expect(v2SQLIsRejected(
            connection,
            "UPDATE legacy_publish_states SET last_published_hash = 'changed'"
        ))
        try connection.execute("UPDATE publish_states SET last_published_hash = 'changed'")
        #expect(v2SQLIsRejected(
            connection,
            "UPDATE publish_states SET source_legacy_locator = NULL"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO publish_states VALUES ('skill-state/x.json', 'skill-state/demo.json', 'x', 1, 1)"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO legacy_migration_ledger VALUES (2, 1, 'completed', X'\(v3Digest)', 1, 0, 0, 1, 2)"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO legacy_migration_ledger VALUES (1, 1, 'completed', X'00', 1, 0, 0, 1, 2)"
        ))
        #expect(v2SQLIsRejected(
            connection,
            "INSERT INTO legacy_migration_ledger VALUES (1, 1, 'completed', X'\(v3Digest)', 2, 0, 0, 1, 2)"
        ))
        try connection.execute(
            """
            INSERT INTO legacy_migration_ledger VALUES (
              1, 1, 'completed', X'\(v3Digest)', 1, 0, 0, 1, 2
            )
            """
        )
        try connection.execute("DELETE FROM publish_states")
        #expect(v2SQLIsRejected(connection, "DELETE FROM legacy_publish_states"))
        #expect(v2SQLIsRejected(
            connection,
            """
            INSERT INTO legacy_publish_states VALUES (
              'skill-state/new.json', 0, X'\(v3Digest)', 'new', 1, 1,
              'unresolved', NULL, NULL, 2
            )
            """
        ))
    }
}

private let v3Digest = String(repeating: "11", count: 32)
private let v3CustomID = "aaaaaaaa111142228333bbbbbbbbbbbb"
private let v3SecondCustomID = "bbbbbbbb222243338444cccccccccccc"

private func insertV3Provenance(_ connection: SQLiteConnection) throws {
    try connection.execute(
        """
        INSERT INTO legacy_publish_states(
          legacy_locator, legacy_format_version, file_digest, last_published_hash,
          last_published_at_ms, hash_algorithm_version, binding_status,
          bound_skill_id, bound_at_ms, migrated_at_ms
        ) VALUES ('skill-state/demo.json', 0, X'\(v3Digest)', 'old', 1, 1,
          'unresolved', NULL, NULL, 2)
        """
    )
    try connection.execute(
        """
        INSERT INTO publish_states(
          runtime_locator, source_legacy_locator, last_published_hash,
          last_published_at_ms, hash_algorithm_version
        ) VALUES ('skill-state/demo.json', 'skill-state/demo.json', 'old', 1, 1)
        """
    )
}
