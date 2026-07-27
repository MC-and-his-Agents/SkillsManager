nonisolated enum SkillSchemaV7 {
    static let version = 7

    static let tableNames = (SkillSchemaV6.tableNames + [
        "distribution_link_ownership",
        "distribution_operations",
    ]).sorted()

    static let indexAndTriggerNames = (SkillSchemaV6.indexAndTriggerNames + [
        "distribution_link_ownership_operation",
        "distribution_operations_active_skill",
        "distribution_operations_skill_id",
    ]).sorted()

    static let fingerprintedObjectNames = (SkillSchemaV6.fingerprintedObjectNames + [
        "distribution_link_ownership",
        "distribution_link_ownership_operation",
        "distribution_operations",
        "distribution_operations_active_skill",
        "distribution_operations_skill_id",
    ]).sorted()

    static let statements = [
        """
        CREATE TABLE distribution_operations (
          operation_id BLOB PRIMARY KEY NOT NULL
            CHECK (typeof(operation_id) = 'blob' AND length(operation_id) = 16),
          format_version INTEGER NOT NULL CHECK (format_version = 1),
          skill_id BLOB NOT NULL REFERENCES skills(skill_id) ON DELETE RESTRICT
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          phase TEXT NOT NULL CHECK (
            phase IN (
              'prepared', 'applying', 'filesystemApplied', 'databaseCommitted',
              'rollingBack', 'cleaning', 'completed'
            )
          ),
          outcome TEXT CHECK (
            outcome IS NULL OR outcome IN ('applied', 'rolledBack', 'needsRepair')
          ),
          old_bindings BLOB NOT NULL
            CHECK (typeof(old_bindings) = 'blob'
              AND length(old_bindings) BETWEEN 1 AND 65536),
          new_bindings BLOB NOT NULL
            CHECK (typeof(new_bindings) = 'blob'
              AND length(new_bindings) BETWEEN 1 AND 65536),
          plan_payload BLOB NOT NULL
            CHECK (typeof(plan_payload) = 'blob'
              AND length(plan_payload) BETWEEN 1 AND 65536),
          preflight_payload BLOB NOT NULL
            CHECK (typeof(preflight_payload) = 'blob'
              AND length(preflight_payload) BETWEEN 1 AND 65536),
          runtime_payload BLOB NOT NULL
            CHECK (typeof(runtime_payload) = 'blob'
              AND length(runtime_payload) BETWEEN 1 AND 65536),
          forward_cursor INTEGER NOT NULL
            CHECK (typeof(forward_cursor) = 'integer' AND forward_cursor >= 0),
          rollback_cursor INTEGER NOT NULL
            CHECK (typeof(rollback_cursor) = 'integer' AND rollback_cursor >= 0),
          cleanup_cursor INTEGER NOT NULL
            CHECK (typeof(cleanup_cursor) = 'integer' AND cleanup_cursor >= 0),
          attempt_count INTEGER NOT NULL
            CHECK (typeof(attempt_count) = 'integer' AND attempt_count >= 0),
          last_error TEXT
            CHECK (last_error IS NULL
              OR length(CAST(last_error AS BLOB)) <= 4096),
          created_at_ms INTEGER NOT NULL
            CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL
            CHECK (typeof(updated_at_ms) = 'integer'
              AND updated_at_ms >= created_at_ms),
          CHECK (
            (outcome IS NULL AND phase <> 'completed')
            OR outcome IS 'needsRepair'
            OR (phase = 'completed' AND outcome IS NOT NULL
              AND outcome IN ('applied', 'rolledBack'))
          )
        ) STRICT
        """,
        """
        CREATE INDEX distribution_operations_skill_id
          ON distribution_operations(skill_id)
        """,
        """
        CREATE UNIQUE INDEX distribution_operations_active_skill
          ON distribution_operations(skill_id)
          WHERE outcome IS NULL OR outcome = 'needsRepair'
        """,
        """
        CREATE TABLE distribution_link_ownership (
          skill_id BLOB NOT NULL
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          target_scope_key TEXT NOT NULL
            CHECK (length(CAST(target_scope_key AS BLOB)) BETWEEN 1 AND 32),
          applied_operation_id BLOB NOT NULL
            REFERENCES distribution_operations(operation_id) ON DELETE RESTRICT
            CHECK (typeof(applied_operation_id) = 'blob'
              AND length(applied_operation_id) = 16),
          root_identity BLOB NOT NULL
            CHECK (typeof(root_identity) = 'blob' AND length(root_identity) = 32),
          entry_identity BLOB NOT NULL
            CHECK (typeof(entry_identity) = 'blob' AND length(entry_identity) = 32),
          absolute_link_target TEXT NOT NULL
            CHECK (length(CAST(absolute_link_target AS BLOB)) BETWEEN 1 AND 8192),
          verified_at_ms INTEGER NOT NULL
            CHECK (typeof(verified_at_ms) = 'integer' AND verified_at_ms >= 0),
          PRIMARY KEY(skill_id, target_scope_key),
          FOREIGN KEY(skill_id, target_scope_key)
            REFERENCES distribution_bindings(skill_id, target_scope_key)
            ON DELETE CASCADE
        ) STRICT
        """,
        """
        CREATE INDEX distribution_link_ownership_operation
          ON distribution_link_ownership(applied_operation_id)
        """,
    ]
}

nonisolated extension SkillSchemaMigrator {
    static func applyV7Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV7.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 7 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 7")
        try beforeCommit()
        try validateV7(connection)
    }

    static func validateV7(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV7.tableNames else {
            throw SQLiteStoreError.invalidState(
                "schema v7 table set is missing or contains unknown tables"
            )
        }
        guard try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV7.version) else {
            throw SQLiteStoreError.invalidState("PRAGMA user_version does not match schema v7")
        }
        try validateMetadata(connection, version: SkillSchemaV7.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV7.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v7 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(
            connection,
            table: "distribution_operations"
        ) == [
            "operation_id", "format_version", "skill_id", "phase", "outcome",
            "old_bindings", "new_bindings", "plan_payload", "preflight_payload",
            "runtime_payload", "forward_cursor", "rollback_cursor", "cleanup_cursor",
            "attempt_count", "last_error", "created_at_ms", "updated_at_ms",
        ], try SkillSchemaInspection.columnNames(
            connection,
            table: "distribution_link_ownership"
        ) == [
            "skill_id", "target_scope_key", "applied_operation_id", "root_identity",
            "entry_identity", "absolute_link_target", "verified_at_ms",
        ], try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV7.tableNames.count), try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV7.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV7SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v7 structure does not match")
        }
        try validateV2CleanupRows(connection)
    }
}
