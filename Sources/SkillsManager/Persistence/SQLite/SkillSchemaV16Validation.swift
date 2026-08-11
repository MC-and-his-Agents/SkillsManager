import Foundation

nonisolated extension SkillSchemaMigrator {
    static func validateV16(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV16.tableNames,
              try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV16.version) else {
            throw SQLiteStoreError.invalidState("schema v16 version or table set does not match")
        }
        try validateMetadata(connection, version: SkillSchemaV16.version)
        try validateV13Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV16.indexAndTriggerNames,
              try SkillSchemaInspection.columnNames(connection, table: "skill_update_checks") == [
                "skill_id", "format_version", "status", "checked_at_ms", "snapshot_payload",
              ],
              try SkillSchemaInspection.columnNames(connection, table: "custom_paths") == [
                "custom_path_id", "absolute_url", "normalized_url_key", "display_name",
                "added_at_ms", "root_mode", "adapter_code",
              ],
              try SkillSchemaInspection.columnNames(connection, table: "repository_catalog") == [
                "repository_id", "normalized_repository_url", "ref_kind", "requested_ref",
                "display_name", "enabled", "created_at_ms", "updated_at_ms", "db_revision",
              ] else {
            throw SQLiteStoreError.invalidState("schema v16 objects or columns do not match")
        }
        guard try connection.querySingleInt(
            "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                + "AND name NOT LIKE 'sqlite_%'"
        ) == Int64(SkillSchemaV16.tableNames.count),
              try SkillSchemaInspection.schemaFingerprint(
                connection,
                objectNames: SkillSchemaV16.fingerprintedObjectNames
              ) == SkillSchemaInspection.expectedV16SchemaFingerprint(),
              try !connection.foreignKeyViolationsExist(),
              try connection.querySingleInt(
                  "SELECT count(*) FROM custom_paths WHERE "
                      + "(root_mode = 'project' AND adapter_code IS NOT NULL) "
                      + "OR (root_mode = 'collection' AND adapter_code IS NULL)"
              ) == 0 else {
            throw SQLiteStoreError.invalidState("schema v16 structure does not match")
        }
        try validateV13CopyProvenanceRows(connection)
        try validateV2CleanupRows(connection)
    }
}
