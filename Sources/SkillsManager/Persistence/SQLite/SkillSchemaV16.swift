import Foundation

nonisolated enum SkillSchemaV16 {
    static let version = 16
    static let tableNames = SkillSchemaV15.tableNames
    static let indexAndTriggerNames = SkillSchemaV15.indexAndTriggerNames
    static let fingerprintedObjectNames = SkillSchemaV15.fingerprintedObjectNames

    static let customPathsSQL = """
    CREATE TABLE custom_paths (
      custom_path_id BLOB PRIMARY KEY
        CHECK (typeof(custom_path_id) = 'blob' AND length(custom_path_id) = 16),
      absolute_url TEXT NOT NULL
        CHECK (length(CAST(absolute_url AS BLOB)) BETWEEN 1 AND 8192),
      normalized_url_key BLOB NOT NULL UNIQUE
        CHECK (typeof(normalized_url_key) = 'blob'
          AND length(normalized_url_key) BETWEEN 1 AND 8192),
      display_name TEXT NOT NULL
        CHECK (length(CAST(display_name AS BLOB)) BETWEEN 1 AND 512),
      added_at_ms INTEGER NOT NULL CHECK (typeof(added_at_ms) = 'integer'),
      root_mode TEXT NOT NULL DEFAULT 'project'
        CHECK (typeof(root_mode) = 'text' AND root_mode IN ('project', 'collection')),
      adapter_code TEXT
        CHECK (adapter_code IS NULL OR (typeof(adapter_code) = 'text'
          AND length(CAST(adapter_code AS BLOB)) BETWEEN 1 AND 16
          AND adapter_code IN ('codex', 'claude', 'opencode', 'copilot'))),
      CHECK ((root_mode = 'project' AND adapter_code IS NULL)
        OR (root_mode = 'collection' AND adapter_code IS NOT NULL))
    ) STRICT
    """

    static let customPathsIdentityTriggerSQL = """
    CREATE TRIGGER custom_paths_id_immutable
    BEFORE UPDATE ON custom_paths
    WHEN NEW.custom_path_id IS NOT OLD.custom_path_id
    BEGIN
      SELECT RAISE(ABORT, 'custom path identity is immutable');
    END
    """

    static let statements = [customPathsSQL, customPathsIdentityTriggerSQL]
}
