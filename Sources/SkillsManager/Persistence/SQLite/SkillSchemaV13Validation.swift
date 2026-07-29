import Foundation

nonisolated extension SkillSchemaMigrator {
    static func validateV13(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV13.tableNames,
              try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV13.version) else {
            throw SQLiteStoreError.invalidState("schema v13 version or table set does not match")
        }
        try validateMetadata(connection, version: SkillSchemaV13.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV13.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v13 indexes or triggers do not match")
        }
        try validateV13Columns(connection)
        guard try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV13.tableNames.count) else {
            throw SQLiteStoreError.invalidState("schema v13 strict table count does not match")
        }
        guard try SkillSchemaInspection.schemaFingerprint(
            connection,
            objectNames: SkillSchemaV13.fingerprintedObjectNames
        ) == SkillSchemaInspection.expectedV13SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v13 SQL fingerprint does not match")
        }
        guard try !connection.foreignKeyViolationsExist() else {
            throw SQLiteStoreError.invalidState("schema v13 foreign keys do not match")
        }
        try validateV13CopyProvenanceRows(connection)
        try validateV2CleanupRows(connection)
    }

    static func validateV13Columns(_ connection: SQLiteConnection) throws {
        guard try SkillSchemaInspection.columnNames(
            connection,
            table: "skill_fork_lineage"
        ) == [
            "fork_skill_id", "parent_skill_id",
            "forked_from_algorithm_version", "forked_from_hash",
            "created_at_ms", "origin_type",
        ], try SkillSchemaInspection.columnNames(
            connection,
            table: "copy_fork_operations"
        ) == [
            "operation_id", "parent_skill_id", "child_skill_id", "parent_revision",
            "scope_kind", "adapter_code", "target_scope_key",
            "distribution_slug", "slug_key",
            "parent_copy_provenance_kind", "parent_provenance_operation_id",
            "parent_content_algorithm_version", "parent_content_fingerprint",
            "parent_tree_algorithm_version", "parent_tree_digest",
            "parent_root_identity", "parent_entry_identity", "parent_verified_at_ms",
            "parent_binding_created_at_ms", "parent_binding_updated_at_ms",
            "observed_content_algorithm_version", "observed_content_fingerprint",
            "observed_tree_algorithm_version", "observed_tree_digest",
            "observed_root_identity", "observed_entry_identity",
            "preview_payload", "phase", "outcome", "verified_at_ms",
            "attempt_count", "last_error", "created_at_ms", "updated_at_ms",
        ], try SkillSchemaInspection.columnNames(
            connection,
            table: "distribution_bindings"
        ) == [
            "skill_id", "scope_kind", "adapter_code", "target_scope_key",
            "distribution_slug", "slug_key", "sync_mode",
            "copy_content_algorithm_version", "copy_content_fingerprint",
            "copy_tree_algorithm_version", "copy_tree_digest",
            "copy_root_identity", "copy_entry_identity",
            "copy_provenance_kind", "copy_applied_operation_id",
            "copy_fork_operation_id", "copy_verified_at_ms",
            "created_at_ms", "updated_at_ms",
        ] else {
            throw SQLiteStoreError.invalidState("schema v13 columns do not match")
        }
    }

    static func validateV13CopyProvenanceRows(
        _ connection: SQLiteConnection
    ) throws {
        let invalidCount = try connection.querySingleInt(
            """
            SELECT count(*)
            FROM distribution_bindings b
            LEFT JOIN distribution_operations d
              ON b.copy_provenance_kind = 'distribution'
             AND d.operation_id = b.copy_applied_operation_id
             AND d.skill_id = b.skill_id
             AND d.format_version IN (2, 3)
            LEFT JOIN copy_fork_operations f
              ON b.copy_provenance_kind = 'copyFork'
             AND f.operation_id = b.copy_fork_operation_id
             AND f.child_skill_id = b.skill_id
             AND f.phase = 'completed'
             AND f.outcome = 'applied'
             AND f.target_scope_key = b.target_scope_key
             AND f.distribution_slug = b.distribution_slug
             AND f.slug_key = b.slug_key
             AND f.observed_content_algorithm_version
                 = b.copy_content_algorithm_version
             AND f.observed_content_fingerprint = b.copy_content_fingerprint
             AND f.observed_tree_algorithm_version = b.copy_tree_algorithm_version
             AND f.observed_tree_digest = b.copy_tree_digest
             AND f.observed_root_identity = b.copy_root_identity
             AND f.observed_entry_identity = b.copy_entry_identity
             AND f.verified_at_ms = b.copy_verified_at_ms
            WHERE b.sync_mode = 'copy'
              AND (
                (b.copy_provenance_kind = 'distribution'
                  AND d.operation_id IS NULL)
                OR
                (b.copy_provenance_kind = 'copyFork'
                  AND f.operation_id IS NULL)
              )
            """
        )
        guard invalidCount == 0 else {
            throw SQLiteStoreError.invalidState(
                "schema v13 Copy provenance rows do not match their operation"
            )
        }
    }
}
