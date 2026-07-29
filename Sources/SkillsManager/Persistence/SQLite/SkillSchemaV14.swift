import Foundation

nonisolated enum SkillSchemaV14 {
    static let version = 14
    static let tableNames = (SkillSchemaV13.tableNames + ["skill_update_checks"]).sorted()
    static let indexAndTriggerNames = SkillSchemaV13.indexAndTriggerNames
    static let fingerprintedObjectNames = (
        SkillSchemaV13.fingerprintedObjectNames + ["skill_update_checks"]
    ).sorted()

    static let updateChecksSQL = """
    CREATE TABLE skill_update_checks (
      skill_id BLOB PRIMARY KEY NOT NULL
        REFERENCES skills(skill_id) ON DELETE CASCADE,
      format_version INTEGER NOT NULL CHECK (format_version = 1),
      status TEXT NOT NULL CHECK (status IN (
        'upToDate','remoteChanged','localModified',
        'copyDrift','capabilityUnavailable','conflict'
      )),
      checked_at_ms INTEGER NOT NULL
        CHECK (typeof(checked_at_ms) = 'integer' AND checked_at_ms >= 0),
      snapshot_payload BLOB NOT NULL
        CHECK (typeof(snapshot_payload) = 'blob'
          AND length(snapshot_payload) BETWEEN 1 AND 65536)
    ) STRICT
    """

    static let statements = [updateChecksSQL]
}
