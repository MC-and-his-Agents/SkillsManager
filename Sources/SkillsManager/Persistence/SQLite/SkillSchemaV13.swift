import Foundation

nonisolated enum SkillSchemaV13 {
    static let version = 13
    static let tableNames = (SkillSchemaV12.tableNames + [
        "copy_fork_operations",
        "skill_fork_lineage",
    ]).sorted()
    static let activeIndexNames = [
        "copy_fork_active_child",
        "copy_fork_active_parent",
        "copy_fork_active_target",
    ]
    static let indexAndTriggerNames = (
        SkillSchemaV12.indexAndTriggerNames
            + activeIndexNames
    ).sorted()
    static let fingerprintedObjectNames = (
        SkillSchemaV12.fingerprintedObjectNames
            + ["copy_fork_operations", "skill_fork_lineage"]
            + activeIndexNames
    ).sorted()

    static let lineageSQL = """
    CREATE TABLE skill_fork_lineage (
      fork_skill_id BLOB PRIMARY KEY NOT NULL
        REFERENCES skills(skill_id) ON DELETE CASCADE
        CHECK (typeof(fork_skill_id) = 'blob' AND length(fork_skill_id) = 16),
      parent_skill_id BLOB NOT NULL
        CHECK (typeof(parent_skill_id) = 'blob' AND length(parent_skill_id) = 16
          AND parent_skill_id <> fork_skill_id),
      forked_from_algorithm_version INTEGER NOT NULL
        CHECK (forked_from_algorithm_version = 1),
      forked_from_hash BLOB NOT NULL
        CHECK (typeof(forked_from_hash) = 'blob' AND length(forked_from_hash) = 32),
      created_at_ms INTEGER NOT NULL
        CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
      origin_type TEXT NOT NULL CHECK (origin_type = 'local-fork')
    ) STRICT
    """

    static let copyForkOperationsSQL = """
    CREATE TABLE copy_fork_operations (
      operation_id BLOB PRIMARY KEY NOT NULL
        CHECK (typeof(operation_id) = 'blob' AND length(operation_id) = 16),
      parent_skill_id BLOB NOT NULL
        CHECK (typeof(parent_skill_id) = 'blob' AND length(parent_skill_id) = 16),
      child_skill_id BLOB UNIQUE NOT NULL
        CHECK (typeof(child_skill_id) = 'blob' AND length(child_skill_id) = 16
          AND child_skill_id <> parent_skill_id),
      parent_revision INTEGER NOT NULL
        CHECK (typeof(parent_revision) = 'integer' AND parent_revision >= 0),
      scope_kind TEXT NOT NULL CHECK (scope_kind IN ('global', 'agent')),
      adapter_code TEXT
        CHECK (adapter_code IS NULL
          OR adapter_code IN ('codex', 'claude', 'opencode', 'copilot')),
      target_scope_key TEXT NOT NULL
        CHECK (length(CAST(target_scope_key AS BLOB)) BETWEEN 1 AND 32),
      distribution_slug TEXT NOT NULL
        CHECK (length(CAST(distribution_slug AS BLOB)) BETWEEN 1 AND 200),
      slug_key TEXT NOT NULL
        CHECK (length(CAST(slug_key AS BLOB)) BETWEEN 1 AND 800),
      parent_copy_provenance_kind TEXT NOT NULL
        CHECK (parent_copy_provenance_kind IN ('distribution', 'copyFork')),
      parent_provenance_operation_id BLOB NOT NULL
        CHECK (typeof(parent_provenance_operation_id) = 'blob'
          AND length(parent_provenance_operation_id) = 16),
      parent_content_algorithm_version INTEGER NOT NULL
        CHECK (parent_content_algorithm_version = 1),
      parent_content_fingerprint BLOB NOT NULL
        CHECK (typeof(parent_content_fingerprint) = 'blob'
          AND length(parent_content_fingerprint) = 32),
      parent_tree_algorithm_version INTEGER NOT NULL
        CHECK (parent_tree_algorithm_version = 1),
      parent_tree_digest BLOB NOT NULL
        CHECK (typeof(parent_tree_digest) = 'blob' AND length(parent_tree_digest) = 32),
      parent_root_identity BLOB NOT NULL
        CHECK (typeof(parent_root_identity) = 'blob' AND length(parent_root_identity) = 32),
      parent_entry_identity BLOB NOT NULL
        CHECK (typeof(parent_entry_identity) = 'blob' AND length(parent_entry_identity) = 32),
      parent_verified_at_ms INTEGER NOT NULL
        CHECK (typeof(parent_verified_at_ms) = 'integer' AND parent_verified_at_ms >= 0),
      parent_binding_created_at_ms INTEGER NOT NULL
        CHECK (typeof(parent_binding_created_at_ms) = 'integer'
          AND parent_binding_created_at_ms >= 0),
      parent_binding_updated_at_ms INTEGER NOT NULL
        CHECK (typeof(parent_binding_updated_at_ms) = 'integer'
          AND parent_binding_updated_at_ms >= parent_binding_created_at_ms),
      observed_content_algorithm_version INTEGER NOT NULL
        CHECK (observed_content_algorithm_version = 1),
      observed_content_fingerprint BLOB NOT NULL
        CHECK (typeof(observed_content_fingerprint) = 'blob'
          AND length(observed_content_fingerprint) = 32),
      observed_tree_algorithm_version INTEGER NOT NULL
        CHECK (observed_tree_algorithm_version = 1),
      observed_tree_digest BLOB NOT NULL
        CHECK (typeof(observed_tree_digest) = 'blob' AND length(observed_tree_digest) = 32),
      observed_root_identity BLOB NOT NULL
        CHECK (typeof(observed_root_identity) = 'blob' AND length(observed_root_identity) = 32),
      observed_entry_identity BLOB NOT NULL
        CHECK (typeof(observed_entry_identity) = 'blob'
          AND length(observed_entry_identity) = 32),
      preview_payload BLOB NOT NULL
        CHECK (typeof(preview_payload) = 'blob'
          AND length(preview_payload) BETWEEN 1 AND 65536),
      phase TEXT NOT NULL CHECK (phase IN ('reserved', 'childCreated', 'completed')),
      outcome TEXT CHECK (outcome IS NULL OR outcome IN ('applied', 'needsRepair')),
      verified_at_ms INTEGER
        CHECK (verified_at_ms IS NULL
          OR (typeof(verified_at_ms) = 'integer' AND verified_at_ms >= 0)),
      attempt_count INTEGER NOT NULL
        CHECK (typeof(attempt_count) = 'integer' AND attempt_count >= 0),
      last_error TEXT
        CHECK (last_error IS NULL OR length(CAST(last_error AS BLOB)) <= 4096),
      created_at_ms INTEGER NOT NULL
        CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
      updated_at_ms INTEGER NOT NULL
        CHECK (typeof(updated_at_ms) = 'integer' AND updated_at_ms >= created_at_ms),
      CHECK (
        (scope_kind = 'global'
          AND adapter_code IS NULL AND target_scope_key = 'global')
        OR (scope_kind = 'agent'
          AND adapter_code IS NOT NULL
          AND target_scope_key = 'agent:' || adapter_code)
      ),
      CHECK (
        (phase IN ('reserved', 'childCreated')
          AND outcome IS NULL AND verified_at_ms IS NULL)
        OR (phase IN ('reserved', 'childCreated')
          AND outcome = 'needsRepair' AND verified_at_ms IS NULL)
        OR (phase = 'completed' AND outcome = 'applied'
          AND verified_at_ms IS NOT NULL)
      )
    ) STRICT
    """

    static let distributionOperationsSQL = SkillSchemaV12.distributionOperationsSQL
        .replacingOccurrences(of: "format_version IN (1, 2)", with: "format_version IN (1, 2, 3)")

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
      sync_mode TEXT NOT NULL CHECK (sync_mode IN ('symlink', 'copy')),
      copy_content_algorithm_version INTEGER,
      copy_content_fingerprint BLOB,
      copy_tree_algorithm_version INTEGER,
      copy_tree_digest BLOB,
      copy_root_identity BLOB,
      copy_entry_identity BLOB,
      copy_provenance_kind TEXT
        CHECK (copy_provenance_kind IS NULL
          OR copy_provenance_kind IN ('distribution', 'copyFork')),
      copy_applied_operation_id BLOB
        REFERENCES distribution_operations(operation_id) ON DELETE RESTRICT,
      copy_fork_operation_id BLOB
        REFERENCES copy_fork_operations(operation_id) ON DELETE RESTRICT,
      copy_verified_at_ms INTEGER,
      created_at_ms INTEGER NOT NULL
        CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
      updated_at_ms INTEGER NOT NULL
        CHECK (typeof(updated_at_ms) = 'integer' AND updated_at_ms >= created_at_ms),
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
          AND copy_provenance_kind IS NULL
          AND copy_applied_operation_id IS NULL
          AND copy_fork_operation_id IS NULL
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
          AND typeof(copy_verified_at_ms) = 'integer'
          AND copy_verified_at_ms >= 0
          AND (
            (copy_provenance_kind = 'distribution'
              AND typeof(copy_applied_operation_id) = 'blob'
              AND length(copy_applied_operation_id) = 16
              AND copy_fork_operation_id IS NULL)
            OR
            (copy_provenance_kind = 'copyFork'
              AND copy_applied_operation_id IS NULL
              AND typeof(copy_fork_operation_id) = 'blob'
              AND length(copy_fork_operation_id) = 16)
          ))
      )
    ) STRICT
    """

    static let activeIndexes = [
        """
        CREATE UNIQUE INDEX copy_fork_active_parent
        ON copy_fork_operations(parent_skill_id)
        WHERE outcome IS NULL OR outcome = 'needsRepair'
        """,
        """
        CREATE UNIQUE INDEX copy_fork_active_child
        ON copy_fork_operations(child_skill_id)
        WHERE outcome IS NULL OR outcome = 'needsRepair'
        """,
        """
        CREATE UNIQUE INDEX copy_fork_active_target
        ON copy_fork_operations(target_scope_key, slug_key)
        WHERE outcome IS NULL OR outcome = 'needsRepair'
        """,
    ]

    static let copyOperationTriggers = [
        """
        CREATE TRIGGER distribution_bindings_copy_operation_insert
        BEFORE INSERT ON distribution_bindings
        WHEN NEW.sync_mode = 'copy' AND (
          (NEW.copy_provenance_kind = 'distribution' AND NOT EXISTS (
            SELECT 1 FROM distribution_operations
            WHERE operation_id = NEW.copy_applied_operation_id
              AND skill_id = NEW.skill_id AND format_version IN (2, 3)
          ))
          OR
          (NEW.copy_provenance_kind = 'copyFork' AND NOT EXISTS (
            SELECT 1 FROM copy_fork_operations
            WHERE operation_id = NEW.copy_fork_operation_id
              AND child_skill_id = NEW.skill_id
              AND phase = 'completed' AND outcome = 'applied'
              AND target_scope_key = NEW.target_scope_key
              AND distribution_slug = NEW.distribution_slug
              AND slug_key = NEW.slug_key
              AND observed_content_algorithm_version
                = NEW.copy_content_algorithm_version
              AND observed_content_fingerprint = NEW.copy_content_fingerprint
              AND observed_tree_algorithm_version = NEW.copy_tree_algorithm_version
              AND observed_tree_digest = NEW.copy_tree_digest
              AND observed_root_identity = NEW.copy_root_identity
              AND observed_entry_identity = NEW.copy_entry_identity
              AND verified_at_ms = NEW.copy_verified_at_ms
          ))
        )
        BEGIN
          SELECT RAISE(ABORT, 'copy binding operation is invalid');
        END
        """,
        """
        CREATE TRIGGER distribution_bindings_copy_operation_update
        BEFORE UPDATE ON distribution_bindings
        WHEN NEW.sync_mode = 'copy' AND (
          (NEW.copy_provenance_kind = 'distribution' AND NOT EXISTS (
            SELECT 1 FROM distribution_operations
            WHERE operation_id = NEW.copy_applied_operation_id
              AND skill_id = NEW.skill_id AND format_version IN (2, 3)
          ))
          OR
          (NEW.copy_provenance_kind = 'copyFork' AND NOT EXISTS (
            SELECT 1 FROM copy_fork_operations
            WHERE operation_id = NEW.copy_fork_operation_id
              AND child_skill_id = NEW.skill_id
              AND phase = 'completed' AND outcome = 'applied'
              AND target_scope_key = NEW.target_scope_key
              AND distribution_slug = NEW.distribution_slug
              AND slug_key = NEW.slug_key
              AND observed_content_algorithm_version
                = NEW.copy_content_algorithm_version
              AND observed_content_fingerprint = NEW.copy_content_fingerprint
              AND observed_tree_algorithm_version = NEW.copy_tree_algorithm_version
              AND observed_tree_digest = NEW.copy_tree_digest
              AND observed_root_identity = NEW.copy_root_identity
              AND observed_entry_identity = NEW.copy_entry_identity
              AND verified_at_ms = NEW.copy_verified_at_ms
          ))
        )
        BEGIN
          SELECT RAISE(ABORT, 'copy binding operation is invalid');
        END
        """,
    ]

    static let statements = [
        lineageSQL,
        copyForkOperationsSQL,
        distributionOperationsSQL,
        distributionBindingsSQL,
    ] + activeIndexes + copyOperationTriggers
}
