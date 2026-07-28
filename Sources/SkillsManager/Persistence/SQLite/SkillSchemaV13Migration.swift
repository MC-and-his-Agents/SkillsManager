import Foundation

nonisolated extension SkillSchemaMigrator {
    static func applyV13Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try backupAndDropV13DependentTables(connection)
        try rebuildV13DistributionOperations(connection)
        try connection.execute(SkillSchemaV13.lineageSQL)
        try connection.execute(SkillSchemaV13.copyForkOperationsSQL)
        for statement in SkillSchemaV13.activeIndexes {
            try connection.execute(statement)
        }
        try rebuildV13DistributionBindings(connection)
        try restoreV13LinkOwnership(connection)
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 13 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 13")
        try beforeCommit()
        try validateV13(connection)
    }

    private static func backupAndDropV13DependentTables(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            CREATE TEMP TABLE distribution_link_ownership_v13_backup AS
            SELECT skill_id, target_scope_key, applied_operation_id, root_identity,
                   entry_identity, absolute_link_target, verified_at_ms
            FROM distribution_link_ownership
            """
        )
        try connection.execute("DROP TABLE distribution_link_ownership")
        try connection.execute(
            """
            CREATE TEMP TABLE distribution_bindings_v13_backup AS
            SELECT skill_id, scope_kind, adapter_code, target_scope_key,
                   distribution_slug, slug_key, sync_mode,
                   copy_content_algorithm_version, copy_content_fingerprint,
                   copy_tree_algorithm_version, copy_tree_digest,
                   copy_root_identity, copy_entry_identity,
                   copy_applied_operation_id, copy_verified_at_ms,
                   created_at_ms, updated_at_ms
            FROM distribution_bindings
            """
        )
        try connection.execute("DROP TABLE distribution_bindings")
    }

    private static func rebuildV13DistributionOperations(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            CREATE TEMP TABLE distribution_operations_v13_backup AS
            SELECT operation_id, format_version, skill_id, phase, outcome,
                   old_bindings, new_bindings, plan_payload, preflight_payload,
                   runtime_payload, forward_cursor, rollback_cursor, cleanup_cursor,
                   attempt_count, last_error, created_at_ms, updated_at_ms
            FROM distribution_operations
            """
        )
        try connection.execute("DROP TABLE distribution_operations")
        try connection.execute(SkillSchemaV13.distributionOperationsSQL)
        try connection.execute(
            """
            INSERT INTO distribution_operations
            SELECT operation_id, format_version, skill_id, phase, outcome,
                   old_bindings, new_bindings, plan_payload, preflight_payload,
                   runtime_payload, forward_cursor, rollback_cursor, cleanup_cursor,
                   attempt_count, last_error, created_at_ms, updated_at_ms
            FROM distribution_operations_v13_backup
            """
        )
        try connection.execute("DROP TABLE distribution_operations_v13_backup")
        try connection.execute(SkillSchemaV7.statements[1])
        try connection.execute(SkillSchemaV7.statements[2])
    }

    private static func rebuildV13DistributionBindings(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(SkillSchemaV13.distributionBindingsSQL)
        try connection.execute(
            """
            INSERT INTO distribution_bindings(
              skill_id, scope_kind, adapter_code, target_scope_key,
              distribution_slug, slug_key, sync_mode,
              copy_content_algorithm_version, copy_content_fingerprint,
              copy_tree_algorithm_version, copy_tree_digest,
              copy_root_identity, copy_entry_identity,
              copy_provenance_kind, copy_applied_operation_id,
              copy_fork_operation_id, copy_verified_at_ms,
              created_at_ms, updated_at_ms
            )
            SELECT skill_id, scope_kind, adapter_code, target_scope_key,
                   distribution_slug, slug_key, sync_mode,
                   copy_content_algorithm_version, copy_content_fingerprint,
                   copy_tree_algorithm_version, copy_tree_digest,
                   copy_root_identity, copy_entry_identity,
                   CASE WHEN sync_mode = 'copy' THEN 'distribution' END,
                   copy_applied_operation_id, NULL, copy_verified_at_ms,
                   created_at_ms, updated_at_ms
            FROM distribution_bindings_v13_backup
            """
        )
        try connection.execute("DROP TABLE distribution_bindings_v13_backup")
        for statement in SkillSchemaV6.statements.dropFirst() {
            try connection.execute(statement)
        }
        for statement in SkillSchemaV13.copyOperationTriggers {
            try connection.execute(statement)
        }
    }

    private static func restoreV13LinkOwnership(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(SkillSchemaV7.statements[3])
        try connection.execute(SkillSchemaV7.statements[4])
        try connection.execute(
            """
            INSERT INTO distribution_link_ownership
            SELECT skill_id, target_scope_key, applied_operation_id, root_identity,
                   entry_identity, absolute_link_target, verified_at_ms
            FROM distribution_link_ownership_v13_backup
            """
        )
        try connection.execute("DROP TABLE distribution_link_ownership_v13_backup")
    }
}
