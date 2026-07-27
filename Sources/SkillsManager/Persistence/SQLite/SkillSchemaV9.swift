nonisolated enum SkillSchemaV9 {
    static let version = 9

    static let expectedSkillsTableSQL = SkillSchemaV2.expectedSkillsTableSQL
        .replacingOccurrences(
            of: """
              CHECK (typeof(db_revision) = 'integer' AND db_revision >= 0),
            """,
            with: """
              CHECK (typeof(db_revision) = 'integer' AND db_revision >= 0),
              restored_from_skill_id BLOB
              CHECK (restored_from_skill_id IS NULL
                OR (typeof(restored_from_skill_id) = 'blob'
                  AND length(restored_from_skill_id) = 16)),
            """
        )

    static let tableNames = (SkillSchemaV8.tableNames + [
        "skill_backups",
        "skill_deletion_operations",
    ]).sorted()

    static let indexAndTriggerNames = (SkillSchemaV8.indexAndTriggerNames + [
        "skill_backups_delete_pruning",
        "skill_backups_immutable_snapshot",
        "skill_backups_lifecycle",
        "skill_backups_locator",
        "skill_backups_original_created",
        "skill_backups_prune_locator",
        "skill_deletion_operations_active_skill",
        "skill_deletion_operations_backup_id",
        "skill_deletion_operations_immutable_snapshot",
        "skill_deletion_operations_lifecycle",
    ]).sorted()

    static let fingerprintedObjectNames = (SkillSchemaV8.fingerprintedObjectNames + [
        "skill_backups",
        "skill_backups_delete_pruning",
        "skill_backups_immutable_snapshot",
        "skill_backups_lifecycle",
        "skill_backups_locator",
        "skill_backups_original_created",
        "skill_backups_prune_locator",
        "skill_deletion_operations",
        "skill_deletion_operations_active_skill",
        "skill_deletion_operations_backup_id",
        "skill_deletion_operations_immutable_snapshot",
        "skill_deletion_operations_lifecycle",
    ]).sorted()

    static let statements = [
        """
        ALTER TABLE skills ADD COLUMN restored_from_skill_id BLOB
          CHECK (restored_from_skill_id IS NULL
            OR (typeof(restored_from_skill_id) = 'blob'
              AND length(restored_from_skill_id) = 16))
        """,
        """
        CREATE TABLE skill_backups (
          backup_id BLOB PRIMARY KEY NOT NULL
            CHECK (typeof(backup_id) = 'blob' AND length(backup_id) = 16),
          format_version INTEGER NOT NULL CHECK (format_version = 1),
          original_skill_id BLOB NOT NULL
            CHECK (typeof(original_skill_id) = 'blob' AND length(original_skill_id) = 16),
          state TEXT NOT NULL
            CHECK (state IN ('preparing', 'available', 'pruning', 'needsRepair')),
          locator TEXT NOT NULL
            CHECK (length(CAST(locator AS BLOB)) BETWEEN 1 AND 4096),
          directory_identity BLOB NOT NULL
            CHECK (typeof(directory_identity) = 'blob' AND length(directory_identity) = 32),
          manifest_digest BLOB NOT NULL
            CHECK (typeof(manifest_digest) = 'blob' AND length(manifest_digest) = 32),
          fingerprint_algorithm_version INTEGER NOT NULL
            CHECK (fingerprint_algorithm_version = 1),
          content_fingerprint BLOB NOT NULL
            CHECK (typeof(content_fingerprint) = 'blob'
              AND length(content_fingerprint) = 32),
          pinned INTEGER NOT NULL DEFAULT 0
            CHECK (typeof(pinned) = 'integer' AND pinned IN (0, 1)),
          restored_skill_id BLOB
            CHECK (restored_skill_id IS NULL
              OR (typeof(restored_skill_id) = 'blob' AND length(restored_skill_id) = 16)),
          restore_result_json BLOB
            CHECK (restore_result_json IS NULL
              OR (typeof(restore_result_json) = 'blob'
                AND length(restore_result_json) BETWEEN 1 AND 131072)),
          prune_quarantine_locator TEXT
            CHECK (prune_quarantine_locator IS NULL
              OR length(CAST(prune_quarantine_locator AS BLOB)) BETWEEN 1 AND 4096),
          prune_quarantine_identity BLOB
            CHECK (prune_quarantine_identity IS NULL
              OR (typeof(prune_quarantine_identity) = 'blob'
                AND length(prune_quarantine_identity) = 32)),
          last_error TEXT
            CHECK (last_error IS NULL
              OR length(CAST(last_error AS BLOB)) BETWEEN 1 AND 4096),
          created_at_ms INTEGER NOT NULL
            CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL
            CHECK (typeof(updated_at_ms) = 'integer'
              AND updated_at_ms >= created_at_ms),
          CHECK (restore_result_json IS NULL OR restored_skill_id IS NOT NULL),
          CHECK (
            (state IN ('preparing', 'available')
              AND prune_quarantine_locator IS NULL
              AND prune_quarantine_identity IS NULL
              AND last_error IS NULL)
            OR (state = 'pruning'
              AND prune_quarantine_locator IS NOT NULL
              AND prune_quarantine_identity IS NOT NULL
              AND last_error IS NULL)
            OR (state = 'needsRepair'
              AND last_error IS NOT NULL
              AND ((prune_quarantine_locator IS NULL
                    AND prune_quarantine_identity IS NULL)
                OR (prune_quarantine_locator IS NOT NULL
                    AND prune_quarantine_identity IS NOT NULL)))
          )
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX skill_backups_locator ON skill_backups(locator)
        """,
        """
        CREATE INDEX skill_backups_original_created
          ON skill_backups(original_skill_id, created_at_ms DESC, backup_id)
        """,
        """
        CREATE UNIQUE INDEX skill_backups_prune_locator
          ON skill_backups(prune_quarantine_locator)
          WHERE prune_quarantine_locator IS NOT NULL
        """,
        """
        CREATE TRIGGER skill_backups_immutable_snapshot
        BEFORE UPDATE ON skill_backups
        WHEN NEW.backup_id IS NOT OLD.backup_id
          OR NEW.format_version IS NOT OLD.format_version
          OR NEW.original_skill_id IS NOT OLD.original_skill_id
          OR NEW.locator IS NOT OLD.locator
          OR NEW.directory_identity IS NOT OLD.directory_identity
          OR NEW.manifest_digest IS NOT OLD.manifest_digest
          OR NEW.fingerprint_algorithm_version IS NOT OLD.fingerprint_algorithm_version
          OR NEW.content_fingerprint IS NOT OLD.content_fingerprint
          OR NEW.created_at_ms IS NOT OLD.created_at_ms
          OR (OLD.restored_skill_id IS NOT NULL
            AND NEW.restored_skill_id IS NOT OLD.restored_skill_id)
          OR (OLD.restore_result_json IS NOT NULL
            AND NEW.restore_result_json IS NOT OLD.restore_result_json)
        BEGIN
          SELECT RAISE(ABORT, 'Skill backup immutable snapshot changed');
        END
        """,
        """
        CREATE TRIGGER skill_backups_lifecycle
        BEFORE UPDATE ON skill_backups
        WHEN NEW.updated_at_ms < OLD.updated_at_ms
          OR NOT (
            NEW.state = OLD.state
            OR (OLD.state = 'preparing' AND NEW.state IN ('available', 'needsRepair'))
            OR (OLD.state = 'available' AND NEW.state IN ('pruning', 'needsRepair'))
            OR (OLD.state = 'pruning' AND NEW.state = 'needsRepair')
            OR (OLD.state = 'needsRepair'
              AND NEW.state IN ('preparing', 'available', 'pruning'))
          )
        BEGIN
          SELECT RAISE(ABORT, 'invalid Skill backup lifecycle transition');
        END
        """,
        """
        CREATE TRIGGER skill_backups_delete_pruning
        BEFORE DELETE ON skill_backups
        WHEN OLD.state NOT IN ('preparing', 'pruning')
        BEGIN
          SELECT RAISE(ABORT, 'only a preparing or quarantined Skill backup can be deleted');
        END
        """,
        """
        CREATE TABLE skill_deletion_operations (
          operation_id BLOB PRIMARY KEY NOT NULL
            CHECK (typeof(operation_id) = 'blob' AND length(operation_id) = 16),
          format_version INTEGER NOT NULL CHECK (format_version = 1),
          skill_id BLOB NOT NULL
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          backup_id BLOB NOT NULL
            CHECK (typeof(backup_id) = 'blob' AND length(backup_id) = 16),
          phase TEXT NOT NULL CHECK (phase IN (
            'prepared', 'backupPublished', 'distributionRemoved',
            'ssotQuarantined', 'databaseCommitted', 'completed'
          )),
          outcome TEXT NOT NULL
            CHECK (outcome IN ('pending', 'applied', 'rolledBack', 'needsRepair')),
          cleanup_state TEXT NOT NULL CHECK (cleanup_state IN (
            'notApplicable', 'notStarted', 'pending', 'completed', 'needsRepair'
          )),
          domain_payload BLOB NOT NULL
            CHECK (typeof(domain_payload) = 'blob'
              AND length(domain_payload) BETWEEN 1 AND 131072),
          expectation_payload BLOB NOT NULL
            CHECK (typeof(expectation_payload) = 'blob'
              AND length(expectation_payload) BETWEEN 1 AND 131072),
          distribution_plan BLOB NOT NULL
            CHECK (typeof(distribution_plan) = 'blob'
              AND length(distribution_plan) BETWEEN 1 AND 131072),
          ssot_identity BLOB NOT NULL
            CHECK (typeof(ssot_identity) = 'blob' AND length(ssot_identity) = 32),
          quarantine_locator TEXT NOT NULL
            CHECK (length(CAST(quarantine_locator AS BLOB)) BETWEEN 1 AND 4096),
          quarantine_identity BLOB
            CHECK (quarantine_identity IS NULL
              OR (typeof(quarantine_identity) = 'blob'
                AND length(quarantine_identity) = 32)),
          attempt_count INTEGER NOT NULL DEFAULT 0
            CHECK (typeof(attempt_count) = 'integer' AND attempt_count >= 0),
          last_error TEXT
            CHECK (last_error IS NULL
              OR length(CAST(last_error AS BLOB)) BETWEEN 1 AND 4096),
          created_at_ms INTEGER NOT NULL
            CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL
            CHECK (typeof(updated_at_ms) = 'integer'
              AND updated_at_ms >= created_at_ms),
          CHECK (
            ((outcome = 'needsRepair' OR cleanup_state = 'needsRepair')
              AND last_error IS NOT NULL)
            OR (outcome <> 'needsRepair' AND cleanup_state <> 'needsRepair'
              AND last_error IS NULL)
          ),
          CHECK (
            (phase IN ('prepared', 'backupPublished', 'distributionRemoved')
              AND outcome IN ('pending', 'needsRepair')
              AND cleanup_state = 'notApplicable'
              AND quarantine_identity IS NULL)
            OR (phase = 'ssotQuarantined'
              AND outcome IN ('pending', 'needsRepair')
              AND cleanup_state = 'notStarted'
              AND quarantine_identity IS NOT NULL)
            OR (phase = 'databaseCommitted'
              AND outcome IN ('pending', 'needsRepair')
              AND cleanup_state IN ('notStarted', 'pending', 'needsRepair')
              AND quarantine_identity IS NOT NULL)
            OR (phase = 'completed' AND outcome = 'applied'
              AND cleanup_state IN ('pending', 'completed', 'needsRepair')
              AND quarantine_identity IS NOT NULL)
            OR (phase = 'completed' AND outcome = 'rolledBack'
              AND cleanup_state = 'notApplicable')
          )
        ) STRICT
        """,
        """
        CREATE INDEX skill_deletion_operations_backup_id
          ON skill_deletion_operations(backup_id)
        """,
        """
        CREATE UNIQUE INDEX skill_deletion_operations_active_skill
          ON skill_deletion_operations(skill_id)
          WHERE outcome IN ('pending', 'needsRepair')
            OR (outcome = 'applied' AND cleanup_state IN ('pending', 'needsRepair'))
        """,
        """
        CREATE TRIGGER skill_deletion_operations_immutable_snapshot
        BEFORE UPDATE ON skill_deletion_operations
        WHEN NEW.operation_id IS NOT OLD.operation_id
          OR NEW.format_version IS NOT OLD.format_version
          OR NEW.skill_id IS NOT OLD.skill_id
          OR NEW.backup_id IS NOT OLD.backup_id
          OR NEW.domain_payload IS NOT OLD.domain_payload
          OR NEW.expectation_payload IS NOT OLD.expectation_payload
          OR NEW.distribution_plan IS NOT OLD.distribution_plan
          OR NEW.ssot_identity IS NOT OLD.ssot_identity
          OR NEW.quarantine_locator IS NOT OLD.quarantine_locator
          OR NEW.created_at_ms IS NOT OLD.created_at_ms
          OR (OLD.quarantine_identity IS NOT NULL
            AND NEW.quarantine_identity IS NOT OLD.quarantine_identity)
        BEGIN
          SELECT RAISE(ABORT, 'Skill deletion immutable snapshot changed');
        END
        """,
        """
        CREATE TRIGGER skill_deletion_operations_lifecycle
        BEFORE UPDATE ON skill_deletion_operations
        WHEN NEW.attempt_count < OLD.attempt_count
          OR NEW.updated_at_ms < OLD.updated_at_ms
          OR NOT (
            (NEW.phase = OLD.phase AND NEW.outcome = OLD.outcome)
            OR (OLD.outcome = 'pending' AND NEW.outcome = 'needsRepair'
              AND NEW.phase = OLD.phase)
            OR (OLD.outcome = 'needsRepair' AND NEW.outcome = 'pending'
              AND NEW.phase = OLD.phase)
            OR (OLD.outcome = 'pending' AND NEW.outcome = 'rolledBack'
              AND NEW.phase = 'completed'
              AND OLD.phase NOT IN ('databaseCommitted', 'completed'))
            OR (OLD.phase = 'prepared' AND NEW.phase = 'backupPublished'
              AND OLD.outcome = 'pending' AND NEW.outcome = 'pending')
            OR (OLD.phase = 'backupPublished' AND NEW.phase = 'distributionRemoved'
              AND OLD.outcome = 'pending' AND NEW.outcome = 'pending')
            OR (OLD.phase = 'distributionRemoved' AND NEW.phase = 'ssotQuarantined'
              AND OLD.outcome = 'pending' AND NEW.outcome = 'pending')
            OR (OLD.phase = 'ssotQuarantined' AND NEW.phase = 'databaseCommitted'
              AND OLD.outcome = 'pending' AND NEW.outcome = 'pending')
            OR (OLD.phase = 'databaseCommitted' AND NEW.phase = 'completed'
              AND OLD.outcome = 'pending' AND NEW.outcome = 'applied')
          )
        BEGIN
          SELECT RAISE(ABORT, 'invalid Skill deletion lifecycle transition');
        END
        """,
    ]
}

nonisolated extension SkillSchemaMigrator {
    static func applyV9Migration(
        _ connection: SQLiteConnection,
        beforeCommit: () throws -> Void
    ) throws {
        for statement in SkillSchemaV9.statements {
            try connection.execute(statement)
        }
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 9 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 9")
        try beforeCommit()
        try validateV9(connection)
    }

    static func validateV9(_ connection: SQLiteConnection) throws {
        guard try connection.userTableNames() == SkillSchemaV9.tableNames,
              try connection.querySingleInt("PRAGMA user_version")
                == Int64(SkillSchemaV9.version) else {
            throw SQLiteStoreError.invalidState("schema v9 version or table set does not match")
        }
        try validateMetadata(connection, version: SkillSchemaV9.version)
        try validateV3Columns(connection)
        let schemaObjects = try SkillSchemaInspection.textValues(
            connection,
            sql: "SELECT name FROM sqlite_schema "
                + "WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard schemaObjects == SkillSchemaV9.indexAndTriggerNames else {
            throw SQLiteStoreError.invalidState("schema v9 indexes or triggers do not match")
        }
        guard try SkillSchemaInspection.columnNames(connection, table: "skills") == [
                "skill_id", "display_name", "default_distribution_slug", "default_slug_key",
                "fingerprint_algorithm_version", "content_fingerprint", "status",
                "created_at_ms", "updated_at_ms", "db_revision", "restored_from_skill_id",
              ] else {
            throw SQLiteStoreError.invalidState("schema v9 skills columns do not match")
        }
        guard try SkillSchemaInspection.columnNames(
                connection,
                table: "skill_backups"
              ) == [
                "backup_id", "format_version", "original_skill_id", "state", "locator",
                "directory_identity", "manifest_digest", "fingerprint_algorithm_version",
                "content_fingerprint", "pinned", "restored_skill_id", "restore_result_json",
                "prune_quarantine_locator", "prune_quarantine_identity", "last_error",
                "created_at_ms", "updated_at_ms",
              ] else {
            throw SQLiteStoreError.invalidState("schema v9 backup columns do not match")
        }
        guard try SkillSchemaInspection.columnNames(
                connection,
                table: "skill_deletion_operations"
              ) == [
                "operation_id", "format_version", "skill_id", "backup_id", "phase",
                "outcome", "cleanup_state", "domain_payload", "expectation_payload",
                "distribution_plan", "ssot_identity", "quarantine_locator",
                "quarantine_identity", "attempt_count", "last_error", "created_at_ms",
                "updated_at_ms",
              ] else {
            throw SQLiteStoreError.invalidState("schema v9 deletion columns do not match")
        }
        guard try connection.querySingleInt(
                "SELECT count(*) FROM pragma_table_list WHERE schema = 'main' AND strict = 1 "
                    + "AND name NOT LIKE 'sqlite_%'"
              ) == Int64(SkillSchemaV9.tableNames.count) else {
            throw SQLiteStoreError.invalidState("schema v9 tables must all be STRICT")
        }
        guard try SkillSchemaInspection.schemaFingerprint(
                connection,
                objectNames: SkillSchemaV9.fingerprintedObjectNames
              ) == SkillSchemaInspection.expectedV9SchemaFingerprint() else {
            throw SQLiteStoreError.invalidState("schema v9 SQL fingerprint does not match")
        }
        try validateV2CleanupRows(connection)
    }
}
