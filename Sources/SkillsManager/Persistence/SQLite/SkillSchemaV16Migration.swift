import Foundation

nonisolated extension SkillSchemaMigrator {
    static func applyV16Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        try connection.execute("DROP TRIGGER custom_paths_id_immutable")
        try connection.execute("ALTER TABLE custom_paths RENAME TO custom_paths_v15")
        try connection.execute(SkillSchemaV16.customPathsSQL)
        try connection.execute(
            """
            INSERT INTO custom_paths(
              custom_path_id, absolute_url, normalized_url_key, display_name, added_at_ms,
              root_mode, adapter_code
            )
            SELECT custom_path_id, absolute_url, normalized_url_key, display_name, added_at_ms,
                   'project', NULL
            FROM custom_paths_v15
            """
        )
        try connection.execute("DROP TABLE custom_paths_v15")
        try connection.execute(SkillSchemaV16.customPathsIdentityTriggerSQL)
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 16 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 16")
        try beforeCommit()
        try validateV16(connection)
    }
}
