nonisolated enum SkillSchemaV3 {
    static let version = 3

    static let tableNames = (SkillSchemaV2.tableNames + [
        "custom_paths",
        "legacy_migration_ledger",
        "legacy_publish_states",
        "publish_states",
    ]).sorted()

    static let indexAndTriggerNames = (SkillSchemaV2.indexAndTriggerNames + [
        "custom_paths_id_immutable",
        "legacy_migration_ledger_immutable",
        "legacy_migration_ledger_no_delete",
        "legacy_publish_states_bound_skill_id",
        "legacy_publish_states_no_delete",
        "legacy_publish_states_no_insert_after_migration",
        "legacy_publish_states_immutable_provenance",
        "publish_states_immutable_identity",
    ]).sorted()

    static let fingerprintedObjectNames = (SkillSchemaV2.fingerprintedObjectNames + [
        "custom_paths",
        "custom_paths_id_immutable",
        "legacy_migration_ledger",
        "legacy_migration_ledger_immutable",
        "legacy_migration_ledger_no_delete",
        "legacy_publish_states",
        "legacy_publish_states_bound_skill_id",
        "legacy_publish_states_no_delete",
        "legacy_publish_states_no_insert_after_migration",
        "legacy_publish_states_immutable_provenance",
        "publish_states",
        "publish_states_immutable_identity",
    ]).sorted()

    static let statements = [
        """
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
          added_at_ms INTEGER NOT NULL CHECK (typeof(added_at_ms) = 'integer')
        ) STRICT
        """,
        """
        CREATE TABLE legacy_publish_states (
          legacy_locator TEXT PRIMARY KEY
            CHECK (
              length(CAST(legacy_locator AS BLOB)) BETWEEN 18 AND 512
              AND \(publishLocatorCheckSQL("legacy_locator"))
            ),
          legacy_format_version INTEGER NOT NULL CHECK (legacy_format_version = 0),
          file_digest BLOB NOT NULL
            CHECK (typeof(file_digest) = 'blob' AND length(file_digest) = 32),
          last_published_hash TEXT NOT NULL
            CHECK (length(CAST(last_published_hash AS BLOB)) BETWEEN 1 AND 512),
          last_published_at_ms INTEGER NOT NULL
            CHECK (typeof(last_published_at_ms) = 'integer'),
          hash_algorithm_version INTEGER
            CHECK (hash_algorithm_version IS NULL OR hash_algorithm_version = 1),
          binding_status TEXT NOT NULL
            CHECK (binding_status IN ('unresolved', 'ambiguous', 'bound')),
          bound_skill_id BLOB REFERENCES skills(skill_id) ON DELETE RESTRICT,
          bound_at_ms INTEGER,
          migrated_at_ms INTEGER NOT NULL
            CHECK (typeof(migrated_at_ms) = 'integer' AND migrated_at_ms >= 0),
          CHECK (
            (binding_status IN ('unresolved', 'ambiguous')
              AND bound_skill_id IS NULL AND bound_at_ms IS NULL)
            OR (binding_status = 'bound'
              AND typeof(bound_skill_id) = 'blob' AND length(bound_skill_id) = 16
              AND typeof(bound_at_ms) = 'integer')
          )
        ) STRICT
        """,
        """
        CREATE TABLE publish_states (
          runtime_locator TEXT PRIMARY KEY
            CHECK (
              length(CAST(runtime_locator AS BLOB)) BETWEEN 18 AND 512
              AND \(publishLocatorCheckSQL("runtime_locator"))
            ),
          source_legacy_locator TEXT UNIQUE
            REFERENCES legacy_publish_states(legacy_locator) ON DELETE RESTRICT,
          last_published_hash TEXT NOT NULL
            CHECK (length(CAST(last_published_hash AS BLOB)) BETWEEN 1 AND 512),
          last_published_at_ms INTEGER NOT NULL
            CHECK (typeof(last_published_at_ms) = 'integer'),
          hash_algorithm_version INTEGER
            CHECK (hash_algorithm_version IS NULL OR hash_algorithm_version = 1),
          CHECK (source_legacy_locator IS NULL OR source_legacy_locator = runtime_locator)
        ) STRICT
        """,
        """
        CREATE TABLE legacy_migration_ledger (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          migration_version INTEGER NOT NULL CHECK (migration_version = 1),
          status TEXT NOT NULL CHECK (status = 'completed'),
          inventory_digest BLOB NOT NULL
            CHECK (typeof(inventory_digest) = 'blob' AND length(inventory_digest) = 32),
          inventory_entry_count INTEGER NOT NULL
            CHECK (typeof(inventory_entry_count) = 'integer' AND inventory_entry_count >= 0),
          custom_paths_file_present INTEGER NOT NULL
            CHECK (custom_paths_file_present IN (0, 1)),
          custom_path_count INTEGER NOT NULL
            CHECK (typeof(custom_path_count) = 'integer' AND custom_path_count >= 0),
          publish_state_count INTEGER NOT NULL
            CHECK (typeof(publish_state_count) = 'integer' AND publish_state_count >= 0),
          completed_at_ms INTEGER NOT NULL
            CHECK (typeof(completed_at_ms) = 'integer' AND completed_at_ms >= 0),
          CHECK (inventory_entry_count = custom_paths_file_present + publish_state_count)
        ) STRICT
        """,
        """
        CREATE INDEX legacy_publish_states_bound_skill_id
          ON legacy_publish_states(bound_skill_id)
        """,
        """
        CREATE TRIGGER custom_paths_id_immutable
        BEFORE UPDATE ON custom_paths
        WHEN NEW.custom_path_id IS NOT OLD.custom_path_id
        BEGIN
          SELECT RAISE(ABORT, 'custom path identity is immutable');
        END
        """,
        """
        CREATE TRIGGER legacy_publish_states_immutable_provenance
        BEFORE UPDATE ON legacy_publish_states
        WHEN NEW.legacy_locator IS NOT OLD.legacy_locator
          OR NEW.legacy_format_version IS NOT OLD.legacy_format_version
          OR NEW.file_digest IS NOT OLD.file_digest
          OR NEW.last_published_hash IS NOT OLD.last_published_hash
          OR NEW.last_published_at_ms IS NOT OLD.last_published_at_ms
          OR NEW.hash_algorithm_version IS NOT OLD.hash_algorithm_version
          OR NEW.migrated_at_ms IS NOT OLD.migrated_at_ms
        BEGIN
          SELECT RAISE(ABORT, 'legacy publish provenance is immutable');
        END
        """,
        """
        CREATE TRIGGER legacy_publish_states_no_delete
        BEFORE DELETE ON legacy_publish_states
        BEGIN
          SELECT RAISE(ABORT, 'legacy publish provenance cannot be deleted');
        END
        """,
        """
        CREATE TRIGGER legacy_publish_states_no_insert_after_migration
        BEFORE INSERT ON legacy_publish_states
        WHEN EXISTS (SELECT 1 FROM legacy_migration_ledger)
        BEGIN
          SELECT RAISE(ABORT, 'legacy publish provenance set is immutable');
        END
        """,
        """
        CREATE TRIGGER publish_states_immutable_identity
        BEFORE UPDATE ON publish_states
        WHEN NEW.runtime_locator IS NOT OLD.runtime_locator
          OR NEW.source_legacy_locator IS NOT OLD.source_legacy_locator
        BEGIN
          SELECT RAISE(ABORT, 'publish state identity is immutable');
        END
        """,
        """
        CREATE TRIGGER legacy_migration_ledger_immutable
        BEFORE UPDATE ON legacy_migration_ledger
        BEGIN
          SELECT RAISE(ABORT, 'legacy migration ledger is immutable');
        END
        """,
        """
        CREATE TRIGGER legacy_migration_ledger_no_delete
        BEFORE DELETE ON legacy_migration_ledger
        BEGIN
          SELECT RAISE(ABORT, 'legacy migration ledger cannot be deleted');
        END
        """,
    ]

    private static func publishLocatorCheckSQL(_ column: String) -> String {
        let leaf = "substr(\(column), 13, length(\(column)) - 17)"
        return "substr(\(column), 1, 12) = 'skill-state/' "
            + "AND substr(\(column), -5) = '.json' "
            + "AND \(leaf) NOT IN ('.', '..') "
            + "AND instr(\(leaf), '/') = 0 "
            + "AND instr(CAST(\(column) AS BLOB), X'00') = 0"
    }
}
