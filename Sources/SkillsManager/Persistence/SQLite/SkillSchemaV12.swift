import Foundation

nonisolated enum SkillSchemaV12 {
    static let version = 12
    static let tableNames = SkillSchemaV11.tableNames
    static let indexAndTriggerNames = (SkillSchemaV11.indexAndTriggerNames + [
        "distribution_bindings_copy_operation_insert",
        "distribution_bindings_copy_operation_update",
    ]).sorted()
    static let fingerprintedObjectNames = (SkillSchemaV11.fingerprintedObjectNames + [
        "distribution_bindings_copy_operation_insert",
        "distribution_bindings_copy_operation_update",
    ]).sorted()

    static let distributionBindingsSQL = """
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
          AND sync_mode IN ('symlink', 'copy')),
      copy_content_algorithm_version INTEGER,
      copy_content_fingerprint BLOB,
      copy_tree_algorithm_version INTEGER,
      copy_tree_digest BLOB,
      copy_root_identity BLOB,
      copy_entry_identity BLOB,
      copy_applied_operation_id BLOB
        REFERENCES distribution_operations(operation_id) ON DELETE RESTRICT,
      copy_verified_at_ms INTEGER,
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
      ),
      CHECK (
        (sync_mode = 'symlink'
          AND copy_content_algorithm_version IS NULL
          AND copy_content_fingerprint IS NULL
          AND copy_tree_algorithm_version IS NULL
          AND copy_tree_digest IS NULL
          AND copy_root_identity IS NULL
          AND copy_entry_identity IS NULL
          AND copy_applied_operation_id IS NULL
          AND copy_verified_at_ms IS NULL)
        OR
        (sync_mode = 'copy'
          AND copy_content_algorithm_version = 1
          AND typeof(copy_content_fingerprint) = 'blob'
          AND length(copy_content_fingerprint) = 32
          AND copy_tree_algorithm_version = 1
          AND typeof(copy_tree_digest) = 'blob'
          AND length(copy_tree_digest) = 32
          AND typeof(copy_root_identity) = 'blob'
          AND length(copy_root_identity) = 32
          AND typeof(copy_entry_identity) = 'blob'
          AND length(copy_entry_identity) = 32
          AND typeof(copy_applied_operation_id) = 'blob'
          AND length(copy_applied_operation_id) = 16
          AND typeof(copy_verified_at_ms) = 'integer'
          AND copy_verified_at_ms >= 0)
      )
    ) STRICT
    """

    static let distributionOperationsSQL = """
    CREATE TABLE distribution_operations (
      operation_id BLOB PRIMARY KEY NOT NULL
        CHECK (typeof(operation_id) = 'blob' AND length(operation_id) = 16),
      format_version INTEGER NOT NULL CHECK (format_version IN (1, 2)),
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
    """

    static let copyOperationTriggers = [
        """
        CREATE TRIGGER distribution_bindings_copy_operation_insert
        BEFORE INSERT ON distribution_bindings
        WHEN NEW.sync_mode = 'copy' AND NOT EXISTS (
          SELECT 1 FROM distribution_operations
          WHERE operation_id = NEW.copy_applied_operation_id
            AND skill_id = NEW.skill_id AND format_version = 2
        )
        BEGIN
          SELECT RAISE(ABORT, 'copy binding operation is invalid');
        END
        """,
        """
        CREATE TRIGGER distribution_bindings_copy_operation_update
        BEFORE UPDATE ON distribution_bindings
        WHEN NEW.sync_mode = 'copy' AND NOT EXISTS (
          SELECT 1 FROM distribution_operations
          WHERE operation_id = NEW.copy_applied_operation_id
            AND skill_id = NEW.skill_id AND format_version = 2
        )
        BEGIN
          SELECT RAISE(ABORT, 'copy binding operation is invalid');
        END
        """,
    ]

    static let statements = [
        distributionBindingsSQL,
        distributionOperationsSQL,
    ] + copyOperationTriggers
}

nonisolated extension SkillSchemaMigrator {
    static func applyV12Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try backupAndDropLinkOwnership(connection)
        try rebuildDistributionOperations(connection)
        try rebuildDistributionBindings(connection)
        try restoreLinkOwnership(connection)
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 12 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 12")
        try beforeCommit()
        try validateV12(connection)
    }

    static func validateV12(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV12.tableNames,
              try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV12.version) else {
            throw SQLiteStoreError.invalidState("schema v12 version or table set does not match")
        }
        try validateMetadata(connection, version: SkillSchemaV12.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV12.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v12 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(
            connection,
            table: "distribution_bindings"
        ) == [
            "skill_id", "scope_kind", "adapter_code", "target_scope_key",
            "distribution_slug", "slug_key", "sync_mode",
            "copy_content_algorithm_version", "copy_content_fingerprint",
            "copy_tree_algorithm_version", "copy_tree_digest",
            "copy_root_identity", "copy_entry_identity",
            "copy_applied_operation_id", "copy_verified_at_ms",
            "created_at_ms", "updated_at_ms",
        ] else {
            throw SQLiteStoreError.invalidState("schema v12 binding columns do not match")
        }
        guard try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV12.tableNames.count) else {
            throw SQLiteStoreError.invalidState("schema v12 strict table count does not match")
        }
        guard try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV12.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV12SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v12 SQL fingerprint does not match")
        }
        guard try !connection.foreignKeyViolationsExist() else {
            throw SQLiteStoreError.invalidState("schema v12 foreign keys do not match")
        }
        try validateV2CleanupRows(connection)
    }

    private static func backupAndDropLinkOwnership(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            CREATE TEMP TABLE distribution_link_ownership_v12_backup AS
            SELECT skill_id, target_scope_key, applied_operation_id, root_identity,
                   entry_identity, absolute_link_target, verified_at_ms
            FROM distribution_link_ownership
            """
        )
        try connection.execute("DROP TABLE distribution_link_ownership")
    }

    private static func rebuildDistributionOperations(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            CREATE TEMP TABLE distribution_operations_v12_backup AS
            SELECT operation_id, format_version, skill_id, phase, outcome,
                   old_bindings, new_bindings, plan_payload, preflight_payload,
                   runtime_payload, forward_cursor, rollback_cursor, cleanup_cursor,
                   attempt_count, last_error, created_at_ms, updated_at_ms
            FROM distribution_operations
            """
        )
        try connection.execute("DROP TABLE distribution_operations")
        try connection.execute(SkillSchemaV12.distributionOperationsSQL)
        try connection.execute(
            """
            INSERT INTO distribution_operations
            SELECT operation_id, format_version, skill_id, phase, outcome,
                   old_bindings, new_bindings, plan_payload, preflight_payload,
                   runtime_payload, forward_cursor, rollback_cursor, cleanup_cursor,
                   attempt_count, last_error, created_at_ms, updated_at_ms
            FROM distribution_operations_v12_backup
            """
        )
        try connection.execute("DROP TABLE distribution_operations_v12_backup")
        try connection.execute(SkillSchemaV7.statements[1])
        try connection.execute(SkillSchemaV7.statements[2])
    }

    private static func rebuildDistributionBindings(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            CREATE TEMP TABLE distribution_bindings_v12_backup AS
            SELECT skill_id, scope_kind, adapter_code, target_scope_key,
                   distribution_slug, slug_key, sync_mode,
                   created_at_ms, updated_at_ms
            FROM distribution_bindings
            """
        )
        try connection.execute("DROP TABLE distribution_bindings")
        try connection.execute(SkillSchemaV12.distributionBindingsSQL)
        try connection.execute(
            """
            INSERT INTO distribution_bindings(
              skill_id, scope_kind, adapter_code, target_scope_key,
              distribution_slug, slug_key, sync_mode,
              created_at_ms, updated_at_ms
            )
            SELECT skill_id, scope_kind, adapter_code, target_scope_key,
                   distribution_slug, slug_key, sync_mode,
                   created_at_ms, updated_at_ms
            FROM distribution_bindings_v12_backup
            """
        )
        try connection.execute("DROP TABLE distribution_bindings_v12_backup")
        for statement in SkillSchemaV6.statements.dropFirst() {
            try connection.execute(statement)
        }
        for statement in SkillSchemaV12.copyOperationTriggers {
            try connection.execute(statement)
        }
    }

    private static func restoreLinkOwnership(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(SkillSchemaV7.statements[3])
        try connection.execute(SkillSchemaV7.statements[4])
        try connection.execute(
            """
            INSERT INTO distribution_link_ownership
            SELECT skill_id, target_scope_key, applied_operation_id, root_identity,
                   entry_identity, absolute_link_target, verified_at_ms
            FROM distribution_link_ownership_v12_backup
            """
        )
        try connection.execute("DROP TABLE distribution_link_ownership_v12_backup")
    }
}
