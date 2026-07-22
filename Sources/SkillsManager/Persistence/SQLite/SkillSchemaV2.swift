nonisolated enum SkillSchemaV2 {
    static let version = 2

    static let tableNames = [
        "cleanup_debts",
        "provider_aliases",
        "schema_metadata",
        "skill_operations",
        "skills",
        "sources",
    ]

    static let indexAndTriggerNames = [
        "cleanup_debts_immutable_ownership",
        "cleanup_debts_insert_consistency",
        "skill_operations_immutable_ownership",
        "skill_operations_insert_prepared",
        "skill_operations_lifecycle",
        "skill_operations_one_unfinished_per_skill",
        "skills_skill_id_immutable",
        "sources_source_id_immutable",
    ]

    static let expectedSkillsTableSQL = SkillSchemaV1.statements[1].replacingOccurrences(
        of: "  updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms),",
        with: """
          updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms), db_revision INTEGER NOT NULL DEFAULT 0
          CHECK (typeof(db_revision) = 'integer' AND db_revision >= 0),
        """
    )

    static let fingerprintedObjectNames = [
        "cleanup_debts",
        "cleanup_debts_immutable_ownership",
        "cleanup_debts_insert_consistency",
        "provider_aliases",
        "schema_metadata",
        "skill_operations",
        "skill_operations_immutable_ownership",
        "skill_operations_insert_prepared",
        "skill_operations_lifecycle",
        "skill_operations_one_unfinished_per_skill",
        "skills",
        "skills_skill_id_immutable",
        "sources",
        "sources_source_id_immutable",
    ]

    static let statements = [
        """
        ALTER TABLE skills ADD COLUMN db_revision INTEGER NOT NULL DEFAULT 0
          CHECK (typeof(db_revision) = 'integer' AND db_revision >= 0)
        """,
        """
        CREATE TABLE skill_operations (
          operation_id BLOB PRIMARY KEY
            CHECK (typeof(operation_id) = 'blob' AND length(operation_id) = 16),
          operation_type TEXT NOT NULL CHECK (operation_type IN ('create', 'replace')),
          skill_id BLOB NOT NULL
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          domain_payload BLOB NOT NULL
            CHECK (typeof(domain_payload) = 'blob' AND length(domain_payload) BETWEEN 1 AND 131072),
          phase TEXT NOT NULL
            CHECK (phase IN ('prepared', 'filesystemApplied', 'databaseCommitted', 'completed')),
          outcome TEXT CHECK (outcome IN ('applied', 'rolledBack', 'needsRepair')),
          staging_locator TEXT NOT NULL,
          final_locator TEXT NOT NULL,
          recovery_locator TEXT,
          old_fingerprint_algorithm_version INTEGER,
          old_content_fingerprint BLOB,
          new_fingerprint_algorithm_version INTEGER NOT NULL
            CHECK (new_fingerprint_algorithm_version = 1),
          new_content_fingerprint BLOB NOT NULL
            CHECK (typeof(new_content_fingerprint) = 'blob' AND length(new_content_fingerprint) = 32),
          expected_staged_identity BLOB NOT NULL
            CHECK (typeof(expected_staged_identity) = 'blob' AND length(expected_staged_identity) = 32),
          expected_old_identity BLOB,
          expected_new_identity BLOB NOT NULL
            CHECK (typeof(expected_new_identity) = 'blob' AND length(expected_new_identity) = 32),
          expected_db_revision INTEGER NOT NULL
            CHECK (typeof(expected_db_revision) = 'integer' AND expected_db_revision >= 0),
          expected_root_identity BLOB NOT NULL
            CHECK (typeof(expected_root_identity) = 'blob' AND length(expected_root_identity) = 32),
          cleanup_state TEXT NOT NULL
            CHECK (cleanup_state IN (
              'notApplicable', 'notStarted', 'pending', 'completed', 'needsRepair'
            )),
          cleanup_debt_id BLOB,
          attempt_count INTEGER NOT NULL DEFAULT 0
            CHECK (typeof(attempt_count) = 'integer' AND attempt_count >= 0),
          last_error TEXT,
          created_at_ms INTEGER NOT NULL
            CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL
            CHECK (typeof(updated_at_ms) = 'integer' AND updated_at_ms >= created_at_ms),
          CHECK (
            (phase = 'completed' AND outcome IN ('applied', 'rolledBack'))
            OR (phase <> 'completed' AND (outcome IS NULL OR outcome = 'needsRepair'))
          ),
          CHECK (
            typeof(staging_locator) = 'text'
            AND length(CAST(staging_locator AS BLOB)) BETWEEN 1 AND 255
            AND staging_locator GLOB '.skillsmanager-tmp-*'
            AND staging_locator NOT GLOB '*/*'
            AND instr(
              staging_locator,
              substr(lower(hex(operation_id)), 1, 8) || '-'
                || substr(lower(hex(operation_id)), 9, 4) || '-'
                || substr(lower(hex(operation_id)), 13, 4) || '-'
                || substr(lower(hex(operation_id)), 17, 4) || '-'
                || substr(lower(hex(operation_id)), 21, 12)
            ) > 0
          ),
          CHECK (
            typeof(final_locator) = 'text'
            AND length(CAST(final_locator AS BLOB)) = 36
            AND final_locator = lower(final_locator)
            AND substr(final_locator, 9, 1) = '-'
            AND substr(final_locator, 14, 1) = '-'
            AND substr(final_locator, 19, 1) = '-'
            AND substr(final_locator, 24, 1) = '-'
            AND final_locator NOT GLOB '*[^0-9a-f-]*'
            AND final_locator = substr(lower(hex(skill_id)), 1, 8) || '-'
              || substr(lower(hex(skill_id)), 9, 4) || '-'
              || substr(lower(hex(skill_id)), 13, 4) || '-'
              || substr(lower(hex(skill_id)), 17, 4) || '-'
              || substr(lower(hex(skill_id)), 21, 12)
          ),
          CHECK (
            (operation_type = 'create'
              AND recovery_locator IS NULL
              AND old_fingerprint_algorithm_version IS NULL
              AND old_content_fingerprint IS NULL
              AND expected_old_identity IS NULL
              AND expected_db_revision = 0)
            OR
            (operation_type = 'replace'
              AND typeof(recovery_locator) = 'text'
              AND length(CAST(recovery_locator AS BLOB)) BETWEEN 1 AND 255
              AND recovery_locator GLOB '.skillsmanager-tmp-*'
              AND recovery_locator NOT GLOB '*/*'
              AND instr(
                recovery_locator,
                substr(lower(hex(operation_id)), 1, 8) || '-'
                  || substr(lower(hex(operation_id)), 9, 4) || '-'
                  || substr(lower(hex(operation_id)), 13, 4) || '-'
                  || substr(lower(hex(operation_id)), 17, 4) || '-'
                  || substr(lower(hex(operation_id)), 21, 12)
              ) > 0
              AND old_fingerprint_algorithm_version = 1
              AND typeof(old_content_fingerprint) = 'blob'
              AND length(old_content_fingerprint) = 32
              AND typeof(expected_old_identity) = 'blob'
              AND length(expected_old_identity) = 32)
          ),
          CHECK (
            (operation_type = 'create' AND (
              (phase <> 'completed'
                AND (outcome IS NULL OR outcome = 'needsRepair')
                AND cleanup_state = 'notApplicable')
              OR (phase = 'completed' AND outcome = 'applied'
                AND cleanup_state = 'notApplicable')
              OR (phase = 'completed' AND outcome = 'rolledBack'
                AND cleanup_state IN ('pending', 'completed', 'needsRepair'))
            ))
            OR (operation_type = 'replace' AND (
              (phase IN ('prepared', 'filesystemApplied')
                AND (outcome IS NULL OR outcome = 'needsRepair')
                AND cleanup_state = 'notStarted')
              OR (phase = 'databaseCommitted'
                AND (outcome IS NULL OR outcome = 'needsRepair')
                AND cleanup_state IN ('notStarted', 'pending', 'completed'))
              OR (phase = 'completed' AND outcome IN ('applied', 'rolledBack')
                AND cleanup_state IN ('pending', 'completed', 'needsRepair'))
            ))
          ),
          CHECK (
            (cleanup_state IN ('pending', 'needsRepair')
              AND typeof(cleanup_debt_id) = 'blob' AND length(cleanup_debt_id) = 16)
            OR (cleanup_state NOT IN ('pending', 'needsRepair') AND cleanup_debt_id IS NULL)
          ),
          CHECK (
            last_error IS NULL
            OR (typeof(last_error) = 'text'
              AND length(CAST(last_error AS BLOB)) BETWEEN 1 AND 4096)
          ),
          UNIQUE(operation_id, cleanup_debt_id),
          FOREIGN KEY(operation_id, cleanup_debt_id)
            REFERENCES cleanup_debts(operation_id, cleanup_debt_id)
            DEFERRABLE INITIALLY DEFERRED
        ) STRICT
        """,
        """
        CREATE TABLE cleanup_debts (
          cleanup_debt_id BLOB PRIMARY KEY
            CHECK (typeof(cleanup_debt_id) = 'blob' AND length(cleanup_debt_id) = 16),
          operation_id BLOB NOT NULL UNIQUE
            REFERENCES skill_operations(operation_id),
          item_role TEXT NOT NULL CHECK (item_role IN ('staging', 'recovery')),
          recovery_locator TEXT NOT NULL,
          expected_item_identity BLOB NOT NULL
            CHECK (typeof(expected_item_identity) = 'blob' AND length(expected_item_identity) = 32),
          expected_fingerprint_algorithm_version INTEGER NOT NULL
            CHECK (expected_fingerprint_algorithm_version = 1),
          expected_content_fingerprint BLOB NOT NULL
            CHECK (typeof(expected_content_fingerprint) = 'blob' AND length(expected_content_fingerprint) = 32),
          expected_root_identity BLOB NOT NULL
            CHECK (typeof(expected_root_identity) = 'blob' AND length(expected_root_identity) = 32),
          attempt_count INTEGER NOT NULL DEFAULT 0
            CHECK (typeof(attempt_count) = 'integer' AND attempt_count >= 0),
          last_error_code TEXT NOT NULL,
          created_at_ms INTEGER NOT NULL
            CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL
            CHECK (typeof(updated_at_ms) = 'integer' AND updated_at_ms >= created_at_ms),
          CHECK (
            typeof(recovery_locator) = 'text'
            AND length(CAST(recovery_locator AS BLOB)) BETWEEN 1 AND 255
            AND recovery_locator GLOB '.skillsmanager-tmp-*'
            AND recovery_locator NOT GLOB '*/*'
          ),
          CHECK (
            typeof(last_error_code) = 'text'
            AND length(CAST(last_error_code AS BLOB)) BETWEEN 1 AND 128
          ),
          UNIQUE(operation_id, cleanup_debt_id),
          FOREIGN KEY(operation_id, cleanup_debt_id)
            REFERENCES skill_operations(operation_id, cleanup_debt_id)
            DEFERRABLE INITIALLY DEFERRED
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX skill_operations_one_unfinished_per_skill
          ON skill_operations(skill_id) WHERE phase <> 'completed'
        """,
        """
        CREATE TRIGGER skill_operations_insert_prepared
        BEFORE INSERT ON skill_operations
        WHEN NEW.phase <> 'prepared'
          OR NEW.outcome IS NOT NULL
          OR NEW.cleanup_debt_id IS NOT NULL
          OR (NEW.operation_type = 'create' AND NEW.cleanup_state <> 'notApplicable')
          OR (NEW.operation_type = 'replace' AND NEW.cleanup_state <> 'notStarted')
        BEGIN
          SELECT RAISE(ABORT, 'skill operation must begin prepared and pending');
        END
        """,
        """
        CREATE TRIGGER skill_operations_immutable_ownership
        BEFORE UPDATE ON skill_operations
        WHEN NEW.operation_id IS NOT OLD.operation_id
          OR NEW.operation_type IS NOT OLD.operation_type
          OR NEW.skill_id IS NOT OLD.skill_id
          OR NEW.domain_payload IS NOT OLD.domain_payload
          OR NEW.staging_locator IS NOT OLD.staging_locator
          OR NEW.final_locator IS NOT OLD.final_locator
          OR NEW.recovery_locator IS NOT OLD.recovery_locator
          OR NEW.old_fingerprint_algorithm_version IS NOT OLD.old_fingerprint_algorithm_version
          OR NEW.old_content_fingerprint IS NOT OLD.old_content_fingerprint
          OR NEW.new_fingerprint_algorithm_version IS NOT OLD.new_fingerprint_algorithm_version
          OR NEW.new_content_fingerprint IS NOT OLD.new_content_fingerprint
          OR NEW.expected_staged_identity IS NOT OLD.expected_staged_identity
          OR NEW.expected_old_identity IS NOT OLD.expected_old_identity
          OR NEW.expected_new_identity IS NOT OLD.expected_new_identity
          OR NEW.expected_db_revision IS NOT OLD.expected_db_revision
          OR NEW.expected_root_identity IS NOT OLD.expected_root_identity
          OR NEW.created_at_ms IS NOT OLD.created_at_ms
        BEGIN
          SELECT RAISE(ABORT, 'skill operation ownership is immutable');
        END
        """,
        """
        CREATE TRIGGER skill_operations_lifecycle
        BEFORE UPDATE ON skill_operations
        WHEN NOT (
            (OLD.phase <> 'completed'
              AND OLD.outcome IS NULL
              AND NEW.phase = OLD.phase
              AND (NEW.outcome IS NULL
                OR (NEW.outcome = 'needsRepair'
                  AND NEW.cleanup_state = OLD.cleanup_state
                  AND NEW.cleanup_debt_id IS OLD.cleanup_debt_id)))
            OR (OLD.phase = 'prepared' AND OLD.outcome IS NULL
              AND NEW.phase = 'filesystemApplied'
              AND NEW.outcome IS NULL
              AND NEW.cleanup_state = OLD.cleanup_state
              AND NEW.cleanup_debt_id IS OLD.cleanup_debt_id)
            OR (OLD.phase = 'filesystemApplied' AND OLD.outcome IS NULL
              AND NEW.phase = 'databaseCommitted'
              AND NEW.outcome IS NULL
              AND NEW.cleanup_state = OLD.cleanup_state
              AND NEW.cleanup_debt_id IS OLD.cleanup_debt_id)
            OR (OLD.phase = 'databaseCommitted'
              AND OLD.outcome IS NULL
              AND NEW.phase = 'completed' AND NEW.outcome = 'applied')
            OR (OLD.phase = 'prepared'
              AND OLD.outcome IS NULL
              AND NEW.phase = 'completed' AND NEW.outcome = 'rolledBack')
            OR (OLD.phase = 'completed'
              AND OLD.cleanup_state = 'pending'
              AND NEW.phase = OLD.phase
              AND NEW.outcome = OLD.outcome
              AND NEW.cleanup_state = 'completed'
              AND NEW.cleanup_debt_id IS NULL)
            OR (OLD.phase = 'completed'
              AND OLD.cleanup_state = 'pending'
              AND NEW.phase = OLD.phase
              AND NEW.outcome = OLD.outcome
              AND NEW.cleanup_state = 'needsRepair'
              AND NEW.cleanup_debt_id IS OLD.cleanup_debt_id)
          )
          OR NEW.attempt_count < OLD.attempt_count
          OR NEW.updated_at_ms < OLD.updated_at_ms
          OR NOT (
            NEW.cleanup_state = OLD.cleanup_state
            OR (OLD.cleanup_state = 'notApplicable'
              AND NEW.cleanup_state IN ('pending', 'completed'))
            OR (OLD.cleanup_state = 'notStarted'
              AND NEW.cleanup_state IN ('pending', 'completed'))
            OR (OLD.cleanup_state = 'pending' AND NEW.cleanup_state = 'completed')
            OR (OLD.cleanup_state = 'pending'
              AND OLD.phase = 'completed'
              AND NEW.cleanup_state = 'needsRepair'
              AND NEW.cleanup_debt_id IS OLD.cleanup_debt_id)
          )
        BEGIN
          SELECT RAISE(ABORT, 'invalid skill operation lifecycle transition');
        END
        """,
        """
        CREATE TRIGGER cleanup_debts_insert_consistency
        BEFORE INSERT ON cleanup_debts
        WHEN NOT EXISTS (
            SELECT 1 FROM skill_operations operation
            WHERE operation.operation_id = NEW.operation_id
              AND operation.cleanup_state = 'pending'
              AND operation.cleanup_debt_id = NEW.cleanup_debt_id
              AND operation.expected_root_identity = NEW.expected_root_identity
              AND (
                (NEW.item_role = 'staging'
                  AND operation.phase = 'completed'
                  AND operation.outcome = 'rolledBack'
                  AND operation.staging_locator = NEW.recovery_locator
                  AND operation.expected_staged_identity = NEW.expected_item_identity
                  AND operation.new_fingerprint_algorithm_version = NEW.expected_fingerprint_algorithm_version
                  AND operation.new_content_fingerprint = NEW.expected_content_fingerprint)
                OR
                (NEW.item_role = 'recovery'
                  AND operation.operation_type = 'replace'
                  AND (
                    (operation.phase = 'databaseCommitted' AND operation.outcome IS NULL)
                    OR (operation.phase = 'completed' AND operation.outcome = 'applied')
                  )
                  AND operation.recovery_locator = NEW.recovery_locator
                  AND operation.expected_old_identity = NEW.expected_item_identity
                  AND operation.old_fingerprint_algorithm_version = NEW.expected_fingerprint_algorithm_version
                  AND operation.old_content_fingerprint = NEW.expected_content_fingerprint)
              )
          )
        BEGIN
          SELECT RAISE(ABORT, 'cleanup debt does not match its operation');
        END
        """,
        """
        CREATE TRIGGER cleanup_debts_immutable_ownership
        BEFORE UPDATE ON cleanup_debts
        WHEN NEW.cleanup_debt_id IS NOT OLD.cleanup_debt_id
          OR NEW.operation_id IS NOT OLD.operation_id
          OR NEW.item_role IS NOT OLD.item_role
          OR NEW.recovery_locator IS NOT OLD.recovery_locator
          OR NEW.expected_item_identity IS NOT OLD.expected_item_identity
          OR NEW.expected_fingerprint_algorithm_version IS NOT OLD.expected_fingerprint_algorithm_version
          OR NEW.expected_content_fingerprint IS NOT OLD.expected_content_fingerprint
          OR NEW.expected_root_identity IS NOT OLD.expected_root_identity
          OR NEW.created_at_ms IS NOT OLD.created_at_ms
          OR NEW.attempt_count < OLD.attempt_count
          OR NEW.updated_at_ms < OLD.updated_at_ms
          OR EXISTS (
            SELECT 1 FROM skill_operations operation
            WHERE operation.operation_id = OLD.operation_id
              AND operation.cleanup_state = 'needsRepair'
          )
        BEGIN
          SELECT RAISE(ABORT, 'cleanup debt ownership or counters are invalid');
        END
        """,
    ]
}
