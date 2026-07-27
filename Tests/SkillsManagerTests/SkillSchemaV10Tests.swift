import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v10", .serialized)
struct SkillSchemaV10Tests {
    enum InjectedFailure: Error {
        case stop
    }

    @Test("migrates v9 through v10 atomically to latest")
    func migratesV9Atomically() throws {
        try withV9Database { connection, databaseURL in
            #expect(throws: InjectedFailure.stop) {
                try SkillSchemaMigrator.migrateIfNeeded(
                    connection,
                    beforeV10Commit: { throw InjectedFailure.stop }
                )
            }
            #expect(try connection.querySingleInt("PRAGMA user_version") == 9)
            #expect(try connection.querySingleInt(
                "SELECT schema_version FROM schema_metadata"
            ) == 9)
            let rolledBackTables = try connection.userTableNames()
            #expect(!rolledBackTables.contains("provider_provenance"))

            try SkillSchemaMigrator.migrateIfNeeded(connection)

            #expect(try connection.querySingleInt("PRAGMA user_version") == 11)
            #expect(try connection.userTableNames() == SkillSchemaV11.tableNames)
            let reader = try SkillSchemaMigrator.open(at: databaseURL, accessMode: .readOnly)
            #expect(reader.accessMode == .readOnly)
        }
    }

    @Test("read-only v9 is rejected")
    func rejectsReadOnlyV9() throws {
        try withV9Database { _, databaseURL in
            #expect(throws: SQLiteStoreError.self) {
                _ = try SkillSchemaMigrator.open(at: databaseURL, accessMode: .readOnly)
            }
        }
    }

    @Test("enforces locator uniqueness, field bounds and cascade deletion")
    func constraints() throws {
        try withV10Database { connection in
            let first = SkillID()
            let second = SkillID()
            try insertSkill(first, slug: "first", connection: connection)
            try insertSkill(second, slug: "second", connection: connection)

            try insertProvenance(
                skillID: first,
                provider: "clawdhub",
                identifier: "Résumé",
                key: SkillContentPath.collisionKey(for: "Résumé"),
                version: "1.0.0",
                connection: connection
            )
            #expect(sqlRejected(connection, provenanceInsertSQL(
                skillID: second,
                provider: "clawdhub",
                identifier: "résumé",
                key: SkillContentPath.collisionKey(for: "résumé"),
                version: nil
            )))
            #expect(sqlRejected(connection, provenanceInsertSQL(
                skillID: first,
                provider: "clawdhub",
                identifier: "another",
                key: SkillContentPath.collisionKey(for: "another"),
                version: nil
            )))
            #expect(sqlRejected(connection, provenanceInsertSQL(
                skillID: second,
                provider: "Clawdhub",
                identifier: "valid",
                key: "valid",
                version: nil
            )))
            #expect(sqlRejected(connection, provenanceInsertSQL(
                skillID: second,
                provider: "clawdhub",
                identifier: String(repeating: "a", count: 201),
                key: "too-long",
                version: nil
            )))
            #expect(sqlRejected(connection, provenanceInsertSQL(
                skillID: second,
                provider: "clawdhub",
                identifier: "valid",
                key: "valid",
                version: String(repeating: "v", count: 513)
            )))

            try connection.execute(
                "DELETE FROM skills WHERE skill_id = X'\(first.bytes.hex)'"
            )
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM provider_provenance"
            ) == 0)
        }
    }
}

private func withV9Database(
    _ body: (SQLiteConnection, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v10-v9-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("manager.sqlite")
    let connection = try SQLiteConnection(url: databaseURL)
    for statement in SkillSchemaV1.statements { try connection.execute(statement) }
    try connection.execute(
        "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 9)"
    )
    for statements in [
        SkillSchemaV2.statements,
        SkillSchemaV3.statements,
        SkillSchemaV4.statements,
        SkillSchemaV5.statements,
        SkillSchemaV6.statements,
        SkillSchemaV7.statements,
        SkillSchemaV8.statements,
        SkillSchemaV9.statements,
    ] {
        for statement in statements { try connection.execute(statement) }
    }
    try connection.execute("PRAGMA user_version = 9")
    try body(connection, databaseURL)
}

private func withV10Database(_ body: (SQLiteConnection) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v10-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(try SkillSchemaMigrator.open(at: root.appendingPathComponent("manager.sqlite")))
}

private func insertSkill(
    _ skillID: SkillID,
    slug: String,
    connection: SQLiteConnection
) throws {
    try connection.execute(
        """
        INSERT INTO skills(
          skill_id, display_name, default_distribution_slug, default_slug_key,
          fingerprint_algorithm_version, content_fingerprint, status,
          created_at_ms, updated_at_ms, db_revision
        ) VALUES (
          X'\(skillID.bytes.hex)', '\(slug)', '\(slug)', '\(slug)', 1,
          zeroblob(32), 'managed', 1, 1, 0
        )
        """
    )
}

private func insertProvenance(
    skillID: SkillID,
    provider: String,
    identifier: String,
    key: String,
    version: String?,
    connection: SQLiteConnection
) throws {
    let statement = try connection.prepare(
        """
        INSERT INTO provider_provenance(
          skill_id, provider, provider_identifier, provider_identifier_key, provider_version
        ) VALUES (?, ?, ?, ?, ?)
        """
    )
    try statement.bind(skillID.bytes, at: 1)
    try statement.bind(provider, at: 2)
    try statement.bind(identifier, at: 3)
    try statement.bind(key, at: 4)
    if let version {
        try statement.bind(version, at: 5)
    } else {
        try statement.bindNull(at: 5)
    }
    _ = try statement.step()
}

private func provenanceInsertSQL(
    skillID: SkillID,
    provider: String,
    identifier: String,
    key: String,
    version: String?
) -> String {
    let versionSQL = version.map { "'\($0)'" } ?? "NULL"
    return """
    INSERT INTO provider_provenance(
      skill_id, provider, provider_identifier, provider_identifier_key, provider_version
    ) VALUES (
      X'\(skillID.bytes.hex)', '\(provider)', '\(identifier)', '\(key)', \(versionSQL)
    )
    """
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
