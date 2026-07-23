nonisolated enum SkillSchemaV4 {
    static let version = 4

    static let tableNames = (SkillSchemaV3.tableNames + [
        "library_bootstrap",
    ]).sorted()

    static let indexAndTriggerNames = (SkillSchemaV3.indexAndTriggerNames + [
        "library_bootstrap_identity_immutable",
        "library_bootstrap_no_delete",
    ]).sorted()

    static let fingerprintedObjectNames = (SkillSchemaV3.fingerprintedObjectNames + [
        "library_bootstrap",
        "library_bootstrap_identity_immutable",
        "library_bootstrap_no_delete",
    ]).sorted()

    static let statements = [
        """
        CREATE TABLE library_bootstrap (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          format_version INTEGER NOT NULL CHECK (format_version = 1),
          bootstrap_kind TEXT NOT NULL CHECK (bootstrap_kind IN ('fresh', 'legacy')),
          bootstrap_id BLOB NOT NULL
            CHECK (typeof(bootstrap_id) = 'blob' AND length(bootstrap_id) = 16),
          expected_marker_identity BLOB NOT NULL
            CHECK (typeof(expected_marker_identity) = 'blob'
              AND length(expected_marker_identity) = 32),
          state TEXT NOT NULL CHECK (state IN ('prepared', 'completed'))
        ) STRICT
        """,
        """
        CREATE TRIGGER library_bootstrap_identity_immutable
        BEFORE UPDATE ON library_bootstrap
        WHEN NEW.singleton IS NOT OLD.singleton
          OR NEW.format_version IS NOT OLD.format_version
          OR NEW.bootstrap_kind IS NOT OLD.bootstrap_kind
          OR NEW.bootstrap_id IS NOT OLD.bootstrap_id
          OR NEW.expected_marker_identity IS NOT OLD.expected_marker_identity
        BEGIN
          SELECT RAISE(ABORT, 'library bootstrap identity is immutable');
        END
        """,
        """
        CREATE TRIGGER library_bootstrap_no_delete
        BEFORE DELETE ON library_bootstrap
        BEGIN
          SELECT RAISE(ABORT, 'library bootstrap provenance cannot be deleted');
        END
        """,
    ]
}
