import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v5")
struct SkillSchemaV5Tests {
    @Test("migrates v4 to v5 atomically")
    func migratesV4Atomically() throws {
        enum InjectedFailure: Error { case stop }
        let location = try schemaV5DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        try downgradeToV4(try SkillSchemaMigrator.open(at: location.database))

        #expect(throws: InjectedFailure.self) {
            _ = try SkillSchemaMigrator.open(at: location.database, beforeV5Commit: {
                throw InjectedFailure.stop
            })
        }
        let rolledBack = try SQLiteConnection(url: location.database)
        #expect(try rolledBack.querySingleInt("PRAGMA user_version") == 4)
        #expect(try rolledBack.userTableNames() == SkillSchemaV4.tableNames)

        let migrated = try SkillSchemaMigrator.open(at: location.database)
        #expect(try migrated.querySingleInt("PRAGMA user_version") == 5)
        #expect(try migrated.userTableNames() == SkillSchemaV5.tableNames)
    }

    @Test("enforces scope shapes, Skill FK, and position uniqueness")
    func enforcesLocalOriginConstraints() throws {
        let location = try schemaV5DatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let connection = try SkillSchemaMigrator.open(at: location.database)
        try connection.execute(v5SkillInsert(id: v5SkillA))
        try connection.execute(v5SkillInsert(id: v5SkillB))

        let invalidRows = [
            v5OriginInsert(skillID: v5UnknownSkill),
            v5OriginInsert(scope: "unknown"),
            v5OriginInsert(adapter: "codex"),
            v5OriginInsert(scope: "agent"),
            v5OriginInsert(scope: "agent", adapter: "codex"),
            v5OriginInsert(
                scope: "agent",
                adapter: "codex",
                variant: ".codex/skills",
                customPathID: v5CustomA
            ),
            v5OriginInsert(
                scope: "custom",
                adapter: "codex",
                variant: ".codex/skills"
            ),
        ]
        for sql in invalidRows {
            #expect(v5SQLIsRejected(connection, sql), "Expected rejection: \(sql)")
        }

        try connection.execute(v5OriginInsert(collisionKey: "global"))
        #expect(v5SQLIsRejected(connection, v5OriginInsert(
            skillID: v5SkillB,
            rawLocator: "Global Two",
            collisionKey: "global"
        )))

        try connection.execute(v5OriginInsert(
            scope: "agent",
            adapter: "codex",
            variant: ".codex/skills",
            rawLocator: "Agent",
            collisionKey: "agent"
        ))
        #expect(v5SQLIsRejected(connection, v5OriginInsert(
            skillID: v5SkillB,
            scope: "agent",
            adapter: "codex",
            variant: ".codex/skills",
            rawLocator: "Agent Two",
            collisionKey: "agent"
        )))
        try connection.execute(v5OriginInsert(
            skillID: v5SkillB,
            scope: "agent",
            adapter: "codex",
            variant: ".codex/skills/public",
            rawLocator: "Agent Other",
            collisionKey: "agent"
        ))

        try connection.execute(v5OriginInsert(
            scope: "custom",
            adapter: "claude",
            variant: ".claude/skills",
            customPathID: v5CustomA,
            rawLocator: "Custom",
            collisionKey: "custom"
        ))
        #expect(v5SQLIsRejected(connection, v5OriginInsert(
            skillID: v5SkillB,
            scope: "custom",
            adapter: "claude",
            variant: ".claude/skills",
            customPathID: v5CustomA,
            rawLocator: "Custom Two",
            collisionKey: "custom"
        )))
        try connection.execute(v5OriginInsert(
            skillID: v5SkillB,
            scope: "custom",
            adapter: "claude",
            variant: ".claude/skills",
            customPathID: v5CustomB,
            rawLocator: "Custom Other",
            collisionKey: "custom"
        ))

        #expect(v5SQLIsRejected(
            connection,
            "DELETE FROM skills WHERE skill_id = X'\(v5SkillA)'"
        ))
    }
}

private let v5SkillA = "00112233445566778899aabbccddeeff"
private let v5SkillB = "11112222333344445555666677778888"
private let v5UnknownSkill = "9999aaaabbbb4ccc8dddeeeeffff0000"
private let v5CustomA = "aaaaaaaa111142228333bbbbbbbbbbbb"
private let v5CustomB = "bbbbbbbb222243338444cccccccccccc"
private let v5Fingerprint = String(repeating: "ab", count: 32)

private func schemaV5DatabaseLocation() throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skillsmanager-v5-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (root, root.appendingPathComponent("manager.sqlite"))
}

private func downgradeToV4(_ connection: SQLiteConnection) throws {
    try connection.execute("BEGIN IMMEDIATE")
    do {
        try connection.execute("DROP TABLE local_skill_origins")
        try connection.execute(
            "UPDATE schema_metadata SET schema_version = 4 WHERE singleton = 1"
        )
        try connection.execute("PRAGMA user_version = 4")
        try connection.execute("COMMIT")
    } catch {
        try? connection.execute("ROLLBACK")
        throw error
    }
}

private func v5SkillInsert(id: String) -> String {
    """
    INSERT INTO skills(
      skill_id, display_name, default_distribution_slug, default_slug_key,
      fingerprint_algorithm_version, content_fingerprint, status,
      created_at_ms, updated_at_ms, db_revision
    ) VALUES (
      X'\(id)', 'Demo', 'demo', 'demo', 1, X'\(v5Fingerprint)',
      'managed', 0, 0, 0
    )
    """
}

private func v5OriginInsert(
    skillID: String = v5SkillA,
    scope: String = "global",
    adapter: String? = nil,
    variant: String? = nil,
    customPathID: String? = nil,
    rawLocator: String = "Demo",
    collisionKey: String = "demo"
) -> String {
    let adapterSQL = adapter.map { "'\($0)'" } ?? "NULL"
    let variantSQL = variant.map { "'\($0)'" } ?? "NULL"
    let customSQL = customPathID.map { "X'\($0)'" } ?? "NULL"
    return """
    INSERT INTO local_skill_origins(
      skill_id, scope_kind, adapter_code, path_variant, custom_path_id,
      raw_locator, normalized_locator, collision_key,
      fingerprint_algorithm_version, content_fingerprint, confirmed_at_ms
    ) VALUES (
      X'\(skillID)', '\(scope)', \(adapterSQL), \(variantSQL), \(customSQL),
      '\(rawLocator)', '\(rawLocator)', '\(collisionKey)',
      1, X'\(v5Fingerprint)', 1
    )
    """
}

private func v5SQLIsRejected(_ connection: SQLiteConnection, _ sql: String) -> Bool {
    do {
        try connection.execute(sql)
        return false
    } catch {
        return true
    }
}
