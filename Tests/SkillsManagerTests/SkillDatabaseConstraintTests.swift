import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database direct SQL constraints")
struct SkillDatabaseConstraintTests {
    @Test("enforces schema metadata singleton and version constraints")
    func enforcesMetadataConstraints() throws {
        try withConstraintDatabase { connection in
            #expect(sqlIsRejected(
                connection,
                "INSERT INTO schema_metadata(singleton, schema_version) VALUES (2, 1)"
            ))
            #expect(sqlIsRejected(
                connection,
                "UPDATE schema_metadata SET singleton = 2 WHERE singleton = 1"
            ))
            #expect(sqlIsRejected(
                connection,
                "UPDATE schema_metadata SET schema_version = 0 WHERE singleton = 1"
            ))
            #expect(sqlIsRejected(
                connection,
                "UPDATE schema_metadata SET schema_version = X'01' WHERE singleton = 1"
            ))
        }
    }

    @Test("enforces every Skill type, range, and enum constraint")
    func enforcesSkillConstraints() throws {
        try withConstraintDatabase { connection in
            let tooLongName = String(repeating: "a", count: 513)
            let tooLongSlug = String(repeating: "a", count: 201)
            let tooLongKey = String(repeating: "a", count: 801)
            let invalidStatements = [
                skillInsert(id: "NULL"),
                skillInsert(id: "'not-a-blob'"),
                skillInsert(id: "X'00'"),
                skillInsert(displayName: "NULL"),
                skillInsert(displayName: "''"),
                skillInsert(displayName: "X'61'"),
                skillInsert(displayName: "'\(tooLongName)'"),
                skillInsert(slug: "NULL"),
                skillInsert(slug: "''"),
                skillInsert(slug: "'\(tooLongSlug)'"),
                skillInsert(slugKey: "NULL"),
                skillInsert(slugKey: "''"),
                skillInsert(slugKey: "'\(tooLongKey)'"),
                skillInsert(algorithm: "NULL"),
                skillInsert(algorithm: "2"),
                skillInsert(algorithm: "X'01'"),
                skillInsert(fingerprint: "NULL"),
                skillInsert(fingerprint: "'not-a-blob'"),
                skillInsert(fingerprint: "X'00'"),
                skillInsert(status: "NULL"),
                skillInsert(status: "'unknown'"),
                skillInsert(created: "NULL"),
                skillInsert(created: "-1"),
                skillInsert(created: "X'00'"),
                skillInsert(updated: "NULL"),
                skillInsert(created: "2", updated: "1"),
            ]
            for sql in invalidStatements {
                #expect(sqlIsRejected(connection, sql), "Expected rejection: \(sql)")
            }

            try connection.execute(skillInsert())
            try connection.execute(skillInsert(
                id: blob(uuidB),
                status: "'needsRepair'",
                created: "1",
                updated: "2"
            ))
            #expect(try connection.querySingleInt("SELECT count(*) FROM skills") == 2)
        }
    }

    @Test("enforces Source constraints and both immutable UUID triggers")
    func enforcesSourceConstraintsAndUUIDImmutability() throws {
        try withConstraintDatabase { connection in
            try connection.execute(skillInsert())
            try connection.execute(skillInsert(id: blob(uuidB)))
            try connection.execute(sourceInsert())

            let tooLongURL = String(repeating: "a", count: 2_049)
            let tooLongSubpath = String(repeating: "a", count: 1_025)
            let tooLongOptional = String(repeating: "a", count: 513)
            let invalidStatements = [
                sourceInsert(sourceID: "NULL", skillID: blob(uuidB)),
                sourceInsert(sourceID: "'not-a-blob'", skillID: blob(uuidB)),
                sourceInsert(sourceID: "X'00'", skillID: blob(uuidB)),
                sourceInsert(sourceID: blob(uuidC), skillID: "NULL"),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidC)),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), repository: "NULL"),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), repository: "''"),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), repository: "X'61'"),
                sourceInsert(
                    sourceID: blob(uuidC),
                    skillID: blob(uuidB),
                    repository: "'\(tooLongURL)'"
                ),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), subpath: "NULL"),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), subpath: "X'61'"),
                sourceInsert(
                    sourceID: blob(uuidC),
                    skillID: blob(uuidB),
                    subpath: "'\(tooLongSubpath)'"
                ),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), revision: "''"),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), revision: "X'61'"),
                sourceInsert(
                    sourceID: blob(uuidC),
                    skillID: blob(uuidB),
                    revision: "'\(tooLongOptional)'"
                ),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), version: "''"),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), version: "X'61'"),
                sourceInsert(
                    sourceID: blob(uuidC),
                    skillID: blob(uuidB),
                    version: "'\(tooLongOptional)'"
                ),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), downloadURL: "''"),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB), downloadURL: "X'61'"),
                sourceInsert(
                    sourceID: blob(uuidC),
                    skillID: blob(uuidB),
                    downloadURL: "'\(tooLongURL)'"
                ),
                sourceInsert(sourceID: blob(uuidC), skillID: blob(uuidB)),
            ]
            for sql in invalidStatements {
                #expect(sqlIsRejected(connection, sql), "Expected rejection: \(sql)")
            }

            try connection.execute(sourceInsert(
                sourceID: blob(uuidC),
                skillID: blob(uuidB),
                repository: "'https://example.com/other'"
            ))
            #expect(sqlIsRejected(connection, sourceInsert(
                sourceID: blob(sourceC),
                skillID: blob(uuidB),
                repository: "'https://example.com/third'"
            )))

            #expect(sqlIsRejected(
                connection,
                "UPDATE skills SET skill_id = \(blob(uuidC)) WHERE skill_id = \(blob(uuidA))"
            ))
            #expect(sqlIsRejected(
                connection,
                "UPDATE sources SET source_id = \(blob(uuidC)) WHERE source_id = \(blob(sourceA))"
            ))
        }
    }

    @Test("enforces Provider aliases and cascades only downward")
    func enforcesAliasesAndCascades() throws {
        try withConstraintDatabase { connection in
            try connection.execute(skillInsert())
            try connection.execute(skillInsert(id: blob(uuidB)))
            try connection.execute(sourceInsert())
            try connection.execute(sourceInsert(
                sourceID: blob(sourceB),
                skillID: blob(uuidB),
                repository: "'https://example.com/other'"
            ))
            try connection.execute(aliasInsert())

            let longProvider = String(repeating: "a", count: 65)
            let longIdentifier = String(repeating: "a", count: 1_025)
            let invalidStatements = [
                aliasInsert(sourceID: "NULL", provider: "'other'", identifier: "'2'"),
                aliasInsert(sourceID: blob(uuidC), provider: "'other'", identifier: "'2'"),
                aliasInsert(sourceID: blob(sourceB), provider: "NULL", identifier: "'2'"),
                aliasInsert(sourceID: blob(sourceB), provider: "''", identifier: "'2'"),
                aliasInsert(sourceID: blob(sourceB), provider: "X'61'", identifier: "'2'"),
                aliasInsert(
                    sourceID: blob(sourceB),
                    provider: "'\(longProvider)'",
                    identifier: "'2'"
                ),
                aliasInsert(sourceID: blob(sourceB), provider: "'other'", identifier: "NULL"),
                aliasInsert(sourceID: blob(sourceB), provider: "'other'", identifier: "''"),
                aliasInsert(sourceID: blob(sourceB), provider: "'other'", identifier: "X'61'"),
                aliasInsert(
                    sourceID: blob(sourceB),
                    provider: "'other'",
                    identifier: "'\(longIdentifier)'"
                ),
                aliasInsert(sourceID: blob(sourceB)),
            ]
            for sql in invalidStatements {
                #expect(sqlIsRejected(connection, sql), "Expected rejection: \(sql)")
            }

            try connection.execute(aliasInsert(
                provider: "'skills.sh'",
                identifier: "'owner/demo'"
            ))
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM provider_aliases WHERE source_id = \(blob(sourceA))"
            ) == 2)

            try connection.execute("DELETE FROM sources WHERE source_id = \(blob(sourceA))")
            #expect(try connection.querySingleInt("SELECT count(*) FROM provider_aliases") == 0)
            #expect(try connection.querySingleInt("SELECT count(*) FROM skills") == 2)

            try connection.execute(aliasInsert(
                sourceID: blob(sourceB),
                provider: "'other'",
                identifier: "'2'"
            ))
            try connection.execute("DELETE FROM skills WHERE skill_id = \(blob(uuidB))")
            #expect(try connection.querySingleInt("SELECT count(*) FROM sources") == 0)
            #expect(try connection.querySingleInt("SELECT count(*) FROM provider_aliases") == 0)
            #expect(try connection.querySingleInt("SELECT count(*) FROM skills") == 1)
        }
    }
}

private let uuidA = "00112233445566778899aabbccddeeff"
private let uuidB = "11112222333344445555666677778888"
private let uuidC = "9999aaaabbbb4ccc8dddeeeeffff0000"
private let sourceA = "aaaaaaaa111142228333bbbbbbbbbbbb"
private let sourceB = "bbbbbbbb222243338444cccccccccccc"
private let sourceC = "cccccccc333344448555dddddddddddd"
private let fingerprint = String(repeating: "ab", count: 32)

private func blob(_ hex: String) -> String { "X'\(hex)'" }

private func skillInsert(
    id: String = blob(uuidA),
    displayName: String = "'Demo'",
    slug: String = "'demo'",
    slugKey: String = "'demo'",
    algorithm: String = "1",
    fingerprint: String = blob(fingerprint),
    status: String = "'managed'",
    created: String = "0",
    updated: String = "0"
) -> String {
    """
    INSERT INTO skills(
      skill_id, display_name, default_distribution_slug, default_slug_key,
      fingerprint_algorithm_version, content_fingerprint, status, created_at_ms, updated_at_ms
    ) VALUES (
      \(id), \(displayName), \(slug), \(slugKey), \(algorithm), \(fingerprint),
      \(status), \(created), \(updated)
    )
    """
}

private func sourceInsert(
    sourceID: String = blob(sourceA),
    skillID: String = blob(uuidA),
    repository: String = "'https://example.com/repository'",
    subpath: String = "''",
    revision: String = "NULL",
    version: String = "NULL",
    downloadURL: String = "NULL"
) -> String {
    """
    INSERT INTO sources(
      source_id, skill_id, normalized_repository_url, normalized_subpath,
      revision, version, download_url
    ) VALUES (
      \(sourceID), \(skillID), \(repository), \(subpath),
      \(revision), \(version), \(downloadURL)
    )
    """
}

private func aliasInsert(
    sourceID: String = blob(sourceA),
    provider: String = "'clawdhub'",
    identifier: String = "'demo'"
) -> String {
    """
    INSERT INTO provider_aliases(source_id, provider, provider_identifier)
    VALUES (\(sourceID), \(provider), \(identifier))
    """
}

private func sqlIsRejected(_ connection: SQLiteConnection, _ sql: String) -> Bool {
    do {
        try connection.execute(sql)
        return false
    } catch {
        return true
    }
}

private func withConstraintDatabase(_ body: (SQLiteConnection) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skillsmanager-constraints-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let connection = try SkillSchemaMigrator.open(at: root.appendingPathComponent("manager.sqlite"))
    try body(connection)
}
