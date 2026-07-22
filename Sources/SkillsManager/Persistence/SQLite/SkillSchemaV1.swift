nonisolated enum SkillSchemaV1 {
    static let version = 1

    static let tableNames = [
        "provider_aliases",
        "schema_metadata",
        "skills",
        "sources",
    ]

    static let statements = [
        """
        CREATE TABLE schema_metadata (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          schema_version INTEGER NOT NULL CHECK (schema_version >= 1)
        ) STRICT
        """,
        """
        CREATE TABLE skills (
          skill_id BLOB PRIMARY KEY
            CHECK (typeof(skill_id) = 'blob' AND length(skill_id) = 16),
          display_name TEXT NOT NULL,
          default_distribution_slug TEXT NOT NULL,
          default_slug_key TEXT NOT NULL,
          fingerprint_algorithm_version INTEGER NOT NULL
            CHECK (fingerprint_algorithm_version = 1),
          content_fingerprint BLOB NOT NULL
            CHECK (typeof(content_fingerprint) = 'blob' AND length(content_fingerprint) = 32),
          status TEXT NOT NULL DEFAULT 'managed'
            CHECK (status IN ('managed', 'needsRepair')),
          created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
          updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms),
          CHECK (length(CAST(display_name AS BLOB)) BETWEEN 1 AND 512),
          CHECK (length(CAST(default_distribution_slug AS BLOB)) BETWEEN 1 AND 200),
          CHECK (length(CAST(default_slug_key AS BLOB)) BETWEEN 1 AND 800)
        ) STRICT
        """,
        """
        CREATE TABLE sources (
          source_id BLOB PRIMARY KEY
            CHECK (typeof(source_id) = 'blob' AND length(source_id) = 16),
          skill_id BLOB NOT NULL UNIQUE
            REFERENCES skills(skill_id) ON DELETE CASCADE,
          normalized_repository_url TEXT NOT NULL,
          normalized_subpath TEXT NOT NULL,
          revision TEXT,
          version TEXT,
          download_url TEXT,
          CHECK (length(CAST(normalized_repository_url AS BLOB)) BETWEEN 1 AND 2048),
          CHECK (length(CAST(normalized_subpath AS BLOB)) <= 1024),
          CHECK (revision IS NULL OR length(CAST(revision AS BLOB)) BETWEEN 1 AND 512),
          CHECK (version IS NULL OR length(CAST(version AS BLOB)) BETWEEN 1 AND 512),
          CHECK (download_url IS NULL OR length(CAST(download_url AS BLOB)) BETWEEN 1 AND 2048),
          UNIQUE(normalized_repository_url, normalized_subpath)
        ) STRICT
        """,
        """
        CREATE TABLE provider_aliases (
          source_id BLOB NOT NULL
            REFERENCES sources(source_id) ON DELETE CASCADE,
          provider TEXT NOT NULL,
          provider_identifier TEXT NOT NULL,
          CHECK (length(CAST(provider AS BLOB)) BETWEEN 1 AND 64),
          CHECK (length(CAST(provider_identifier AS BLOB)) BETWEEN 1 AND 1024),
          PRIMARY KEY(provider, provider_identifier)
        ) STRICT
        """,
        """
        CREATE TRIGGER skills_skill_id_immutable
        BEFORE UPDATE OF skill_id ON skills
        BEGIN
          SELECT RAISE(ABORT, 'skills.skill_id is immutable');
        END
        """,
        """
        CREATE TRIGGER sources_source_id_immutable
        BEFORE UPDATE OF source_id ON sources
        BEGIN
          SELECT RAISE(ABORT, 'sources.source_id is immutable');
        END
        """,
    ]
}
