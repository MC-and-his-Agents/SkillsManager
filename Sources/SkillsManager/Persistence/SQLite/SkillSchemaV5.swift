nonisolated enum SkillSchemaV5 {
    static let version = 5

    static let tableNames = (SkillSchemaV4.tableNames + [
        "local_skill_origins",
    ]).sorted()

    static let indexAndTriggerNames = (SkillSchemaV4.indexAndTriggerNames + [
        "local_skill_origins_agent_position",
        "local_skill_origins_custom_position",
        "local_skill_origins_global_position",
        "local_skill_origins_skill_id",
    ]).sorted()

    static let fingerprintedObjectNames = (SkillSchemaV4.fingerprintedObjectNames + [
        "local_skill_origins",
        "local_skill_origins_agent_position",
        "local_skill_origins_custom_position",
        "local_skill_origins_global_position",
        "local_skill_origins_skill_id",
    ]).sorted()

    static let statements = [
        """
        CREATE TABLE local_skill_origins (
          skill_id BLOB NOT NULL REFERENCES skills(skill_id) ON DELETE RESTRICT
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          scope_kind TEXT NOT NULL CHECK (scope_kind IN ('global', 'agent', 'custom')),
          adapter_code TEXT
            CHECK (adapter_code IS NULL
              OR length(CAST(adapter_code AS BLOB)) BETWEEN 1 AND 128),
          path_variant TEXT
            CHECK (path_variant IS NULL
              OR length(CAST(path_variant AS BLOB)) BETWEEN 1 AND 1024),
          custom_path_id BLOB
            CHECK (custom_path_id IS NULL
              OR (typeof(custom_path_id) = 'blob' AND length(custom_path_id) = 16)),
          raw_locator TEXT NOT NULL
            CHECK (length(CAST(raw_locator AS BLOB)) BETWEEN 1 AND 1024),
          normalized_locator TEXT NOT NULL
            CHECK (length(CAST(normalized_locator AS BLOB)) BETWEEN 1 AND 1024),
          collision_key TEXT NOT NULL
            CHECK (length(CAST(collision_key AS BLOB)) BETWEEN 1 AND 4096),
          fingerprint_algorithm_version INTEGER NOT NULL
            CHECK (fingerprint_algorithm_version = 1),
          content_fingerprint BLOB NOT NULL
            CHECK (typeof(content_fingerprint) = 'blob'
              AND length(content_fingerprint) = 32),
          confirmed_at_ms INTEGER NOT NULL
            CHECK (typeof(confirmed_at_ms) = 'integer' AND confirmed_at_ms >= 0),
          CHECK (
            (scope_kind = 'global'
              AND adapter_code IS NULL AND path_variant IS NULL AND custom_path_id IS NULL)
            OR (scope_kind = 'agent'
              AND adapter_code IS NOT NULL AND path_variant IS NOT NULL
              AND custom_path_id IS NULL)
            OR (scope_kind = 'custom'
              AND adapter_code IS NOT NULL AND path_variant IS NOT NULL
              AND custom_path_id IS NOT NULL)
          )
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX local_skill_origins_global_position
          ON local_skill_origins(collision_key)
          WHERE scope_kind = 'global'
        """,
        """
        CREATE UNIQUE INDEX local_skill_origins_agent_position
          ON local_skill_origins(adapter_code, path_variant, collision_key)
          WHERE scope_kind = 'agent'
        """,
        """
        CREATE UNIQUE INDEX local_skill_origins_custom_position
          ON local_skill_origins(custom_path_id, adapter_code, path_variant, collision_key)
          WHERE scope_kind = 'custom'
        """,
        """
        CREATE INDEX local_skill_origins_skill_id
          ON local_skill_origins(skill_id)
        """,
    ]
}

nonisolated extension SkillSchemaMigrator {
    static func migrateV3ToV5(
        _ connection: SQLiteConnection,
        beforeV4Commit: () throws -> Void,
        beforeV5Commit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV5.version) {
                try validateV5(connection)
                try connection.execute("COMMIT")
                return
            }
            if lockedVersion == Int64(SkillSchemaV4.version) {
                try validateV4(connection)
                try applyV5Migration(connection, beforeCommit: beforeV5Commit)
                try connection.execute("COMMIT")
                return
            }
            guard lockedVersion == Int64(SkillSchemaV3.version) else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            try validateV3(connection)
            try applyV4Migration(connection, beforeCommit: beforeV4Commit)
            try applyV5Migration(connection, beforeCommit: beforeV5Commit)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    static func migrateV4ToV5(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            guard let lockedVersion = try connection.querySingleInt("PRAGMA user_version") else {
                throw SQLiteStoreError.invalidState("PRAGMA user_version returned no row")
            }
            if lockedVersion == Int64(SkillSchemaV5.version) {
                try validateV5(connection)
                try connection.execute("COMMIT")
                return
            }
            guard lockedVersion == Int64(SkillSchemaV4.version) else {
                throw SQLiteStoreError.invalidState(
                    "schema version changed to unsupported value \(lockedVersion)"
                )
            }
            try validateV4(connection)
            try applyV5Migration(connection, beforeCommit: beforeCommit)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    static func applyV5Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV5.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 5 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 5")
        try beforeCommit()
        try validateV5(connection)
    }

    static func validateV5(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV5.tableNames else {
            throw SQLiteStoreError.invalidState(
                "schema v5 table set is missing or contains unknown tables"
            )
        }
        guard try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV5.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v5")
        }
        try validateMetadata(connection, version: SkillSchemaV5.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV5.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v5 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(
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
        ) == Int64(SkillSchemaV5.tableNames.count), try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV5.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV5SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v5 structure does not match")
        }
        try validateV2CleanupRows(connection)
    }
}
