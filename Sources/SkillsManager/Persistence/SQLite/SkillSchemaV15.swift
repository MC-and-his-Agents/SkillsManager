import Foundation

nonisolated enum SkillSchemaV15 {
    static let version = 15
    static let tableNames = (SkillSchemaV14.tableNames + ["repository_catalog"]).sorted()
    static let indexAndTriggerNames = SkillSchemaV14.indexAndTriggerNames
    static let fingerprintedObjectNames = (
        SkillSchemaV14.fingerprintedObjectNames + ["repository_catalog"]
    ).sorted()

    static let repositoryCatalogSQL = """
    CREATE TABLE repository_catalog (
      repository_id BLOB PRIMARY KEY NOT NULL
        CHECK (typeof(repository_id) = 'blob' AND length(repository_id) = 16),
      normalized_repository_url TEXT NOT NULL UNIQUE
        CHECK (typeof(normalized_repository_url) = 'text'
          AND length(CAST(normalized_repository_url AS BLOB)) BETWEEN 1 AND 2048),
      ref_kind TEXT NOT NULL CHECK (ref_kind IN ('defaultBranch','explicit')),
      requested_ref TEXT
        CHECK (requested_ref IS NULL OR (typeof(requested_ref) = 'text'
          AND length(CAST(requested_ref AS BLOB)) BETWEEN 1 AND 512)),
      display_name TEXT NOT NULL
        CHECK (typeof(display_name) = 'text'
          AND length(CAST(display_name AS BLOB)) BETWEEN 1 AND 512),
      enabled INTEGER NOT NULL CHECK (typeof(enabled) = 'integer' AND enabled IN (0,1)),
      created_at_ms INTEGER NOT NULL
        CHECK (typeof(created_at_ms) = 'integer' AND created_at_ms >= 0),
      updated_at_ms INTEGER NOT NULL
        CHECK (typeof(updated_at_ms) = 'integer'
          AND updated_at_ms >= created_at_ms),
      db_revision INTEGER NOT NULL DEFAULT 0
        CHECK (typeof(db_revision) = 'integer' AND db_revision >= 0),
      CHECK ((ref_kind = 'defaultBranch' AND requested_ref IS NULL)
        OR (ref_kind = 'explicit' AND requested_ref IS NOT NULL))
    ) STRICT
    """

    static let statements = [repositoryCatalogSQL]
}
