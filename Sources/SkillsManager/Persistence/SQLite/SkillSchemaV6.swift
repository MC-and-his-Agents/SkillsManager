nonisolated enum SkillSchemaV6 {
    static let version = 6

    static let tableNames = (SkillSchemaV5.tableNames + [
        "distribution_bindings",
    ]).sorted()

    static let indexAndTriggerNames = (SkillSchemaV5.indexAndTriggerNames + [
        "distribution_bindings_scope_insert",
        "distribution_bindings_scope_update",
        "distribution_bindings_target_slug",
        "distribution_bindings_time_update",
    ]).sorted()

    static let fingerprintedObjectNames = (SkillSchemaV5.fingerprintedObjectNames + [
        "distribution_bindings",
        "distribution_bindings_scope_insert",
        "distribution_bindings_scope_update",
        "distribution_bindings_target_slug",
        "distribution_bindings_time_update",
    ]).sorted()

    static let statements = [
        """
        CREATE TABLE distribution_bindings (
          skill_id BLOB NOT NULL REFERENCES skills(skill_id) ON DELETE CASCADE
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          scope_kind TEXT NOT NULL
            CHECK (length(CAST(scope_kind AS BLOB)) BETWEEN 1 AND 16
              AND scope_kind IN ('global', 'agent')),
          adapter_code TEXT
            CHECK (adapter_code IS NULL
              OR (length(CAST(adapter_code AS BLOB)) BETWEEN 1 AND 16
                AND adapter_code IN ('codex', 'claude', 'opencode', 'copilot'))),
          target_scope_key TEXT NOT NULL
            CHECK (length(CAST(target_scope_key AS BLOB)) BETWEEN 1 AND 32),
          distribution_slug TEXT NOT NULL
            CHECK (length(CAST(distribution_slug AS BLOB)) BETWEEN 1 AND 200),
          slug_key TEXT NOT NULL
            CHECK (length(CAST(slug_key AS BLOB)) BETWEEN 1 AND 800),
          sync_mode TEXT NOT NULL
            CHECK (length(CAST(sync_mode AS BLOB)) BETWEEN 1 AND 16
              AND sync_mode = 'symlink'),
          created_at_ms INTEGER NOT NULL
            CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL
            CHECK (typeof(updated_at_ms) = 'integer'
              AND updated_at_ms >= created_at_ms),
          PRIMARY KEY(skill_id, target_scope_key),
          CHECK (
            (scope_kind = 'global'
              AND adapter_code IS NULL AND target_scope_key = 'global')
            OR (scope_kind = 'agent'
              AND adapter_code IS NOT NULL
              AND target_scope_key = 'agent:' || adapter_code)
          )
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX distribution_bindings_target_slug
          ON distribution_bindings(target_scope_key, slug_key)
        """,
        """
        CREATE TRIGGER distribution_bindings_scope_insert
        BEFORE INSERT ON distribution_bindings
        WHEN EXISTS (
          SELECT 1 FROM distribution_bindings
          WHERE skill_id = NEW.skill_id AND scope_kind <> NEW.scope_kind
        )
        BEGIN
          SELECT RAISE(ABORT, 'distribution binding scope conflict');
        END
        """,
        """
        CREATE TRIGGER distribution_bindings_scope_update
        BEFORE UPDATE ON distribution_bindings
        WHEN EXISTS (
          SELECT 1 FROM distribution_bindings
          WHERE skill_id = NEW.skill_id AND scope_kind <> NEW.scope_kind
            AND NOT (
              skill_id = OLD.skill_id AND target_scope_key = OLD.target_scope_key
            )
        )
        BEGIN
          SELECT RAISE(ABORT, 'distribution binding scope conflict');
        END
        """,
        """
        CREATE TRIGGER distribution_bindings_time_update
        BEFORE UPDATE ON distribution_bindings
        WHEN NEW.created_at_ms <> OLD.created_at_ms
          OR NEW.updated_at_ms < OLD.updated_at_ms
        BEGIN
          SELECT RAISE(ABORT, 'distribution binding time regression');
        END
        """,
    ]
}

nonisolated extension SkillSchemaMigrator {
    static func migrateV3ToV6(
        _ connection: SQLiteConnection,
        beforeV4Commit: () throws -> Void,
        beforeV5Commit: () throws -> Void,
        beforeV6Commit: () throws -> Void
    ) throws {
        try migrateV3OrNewerToV6(
            connection,
            minimumVersion: SkillSchemaV3.version,
            beforeV4Commit: beforeV4Commit,
            beforeV5Commit: beforeV5Commit,
            beforeV6Commit: beforeV6Commit
        )
    }

    static func migrateV4ToV6(
        _ connection: SQLiteConnection,
        beforeV5Commit: () throws -> Void,
        beforeV6Commit: () throws -> Void
    ) throws {
        try migrateV3OrNewerToV6(
            connection,
            minimumVersion: SkillSchemaV4.version,
            beforeV4Commit: {},
            beforeV5Commit: beforeV5Commit,
            beforeV6Commit: beforeV6Commit
        )
    }

    static func migrateV5ToV6(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try migrateV3OrNewerToV6(
            connection,
            minimumVersion: SkillSchemaV5.version,
            beforeV4Commit: {},
            beforeV5Commit: {},
            beforeV6Commit: beforeCommit
        )
    }

    static func applyV6Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV6.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 6 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 6")
        try beforeCommit()
        try validateV6(connection)
    }

    static func validateV6(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV6.tableNames else {
            throw SQLiteStoreError.invalidState(
                "schema v6 table set is missing or contains unknown tables"
            )
        }
        guard try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV6.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v6")
        }
        try validateMetadata(connection, version: SkillSchemaV6.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV6.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v6 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(
            connection,
            table: "distribution_bindings"
        ) == [
            "skill_id", "scope_kind", "adapter_code", "target_scope_key",
            "distribution_slug", "slug_key", "sync_mode",
            "created_at_ms", "updated_at_ms",
        ], try SkillSchemaInspection.columnNames(
            connection,
            table: "local_skill_origins"
        ) == [
            "skill_id", "scope_kind", "adapter_code", "path_variant", "custom_path_id",
            "raw_locator", "normalized_locator", "collision_key",
            "fingerprint_algorithm_version", "content_fingerprint", "confirmed_at_ms",
        ], try SkillSchemaInspection.columnNames(connection, table: "library_bootstrap") == [
            "singleton", "format_version", "bootstrap_kind", "bootstrap_id",
            "expected_marker_identity", "state",
        ], try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV6.tableNames.count), try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV6.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV6SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v6 structure does not match")
        }
        try validateV2CleanupRows(connection)
    }

    private static func migrateV3OrNewerToV6(
        _ connection: SQLiteConnection,
        minimumVersion: Int,
        beforeV4Commit: () throws -> Void,
        beforeV5Commit: () throws -> Void,
        beforeV6Commit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            guard lockedVersion >= Int64(minimumVersion),
                  lockedVersion <= Int64(SkillSchemaV6.version) else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            switch lockedVersion {
            case Int64(SkillSchemaV6.version):
                try validateV6(connection)
            case Int64(SkillSchemaV5.version):
                try validateV5(connection)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
            case Int64(SkillSchemaV4.version):
                try validateV4(connection)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
            case Int64(SkillSchemaV3.version):
                try validateV3(connection)
                try applyV4Migration(connection, beforeCommit: beforeV4Commit)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try applyV6Migration(connection, beforeCommit: beforeV6Commit)
            default:
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }
}
