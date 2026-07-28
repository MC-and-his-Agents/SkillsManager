import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill database schema v11", .serialized)
struct SkillSchemaV11Tests {
    enum InjectedFailure: Error {
        case stop
    }

    @Test("migrates one-to-one publish state atomically and accepts read-only current schema")
    func migratesOneToOneAtomically() throws {
        try withV10Database { connection, databaseURL in
            let skillID = SkillID()
            try insertV11TestSkill(skillID, slug: "Résumé", connection: connection)
            try insertLegacyPublishState(
                locator: "skill-state/Résumé.json",
                hash: "old",
                connection: connection
            )

            #expect(throws: InjectedFailure.stop) {
                try SkillSchemaMigrator.migrateIfNeeded(
                    connection,
                    beforeV11Commit: { throw InjectedFailure.stop }
                )
            }
            #expect(try connection.querySingleInt("PRAGMA user_version") == 10)
            #expect(!(try connection.userTableNames()).contains("managed_publish_states"))
            #expect(try connection.querySingleText(
                "SELECT binding_status FROM legacy_publish_states"
            ) == "unresolved")

            try SkillSchemaMigrator.migrateIfNeeded(connection)
            #expect(try connection.querySingleInt("PRAGMA user_version") == 13)
            #expect(try ManagedPublishStateStore(connection: connection).load(skillID: skillID)
                == SQLitePublishState(
                    lastPublishedHash: "old",
                    lastPublishedAtMilliseconds: 10,
                    hashAlgorithmVersion: 1
                ))
            #expect(try connection.querySingleText(
                "SELECT binding_status FROM legacy_publish_states"
            ) == "bound")

            try deleteV11Skill(skillID, connection: connection)
            #expect(try ManagedPublishStateStore(connection: connection).load(skillID: skillID) == nil)
            #expect(try connection.querySingleText(
                "SELECT binding_status FROM legacy_publish_states"
            ) == "unresolved")
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM legacy_publish_states WHERE bound_skill_id IS NOT NULL"
            ) == 0)

            let reader = try SkillSchemaMigrator.open(at: databaseURL, accessMode: .readOnly)
            #expect(reader.accessMode == .readOnly)
        }
    }

    @Test("ambiguous, unmatched and non-NFC locators remain unbound")
    func refusesAmbiguousAndInvalidCandidates() throws {
        try withV10Database { connection, _ in
            let first = SkillID()
            let duplicateA = SkillID()
            let duplicateB = SkillID()
            try insertV11TestSkill(first, slug: "Résumé", connection: connection)
            try insertV11TestSkill(duplicateA, slug: "Duplicate", connection: connection)
            try insertV11TestSkill(duplicateB, slug: "duplicate", connection: connection)

            for locator in [
                "skill-state/Résumé.json",
                "skill-state/résumé.json",
                "skill-state/Duplicate.json",
                "skill-state/unmatched.json",
                "skill-state/Re\u{301}sume\u{301}.json",
            ] {
                try insertLegacyPublishState(locator: locator, hash: locator, connection: connection)
            }

            try SkillSchemaMigrator.migrateIfNeeded(connection)

            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM managed_publish_states"
            ) == 0)
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM legacy_publish_states WHERE binding_status = 'ambiguous'"
            ) == 3)
            #expect(try connection.querySingleInt(
                "SELECT count(*) FROM legacy_publish_states WHERE binding_status = 'unresolved'"
            ) == 2)
        }
    }

    @Test("managed state keeps stable identity and cascades with its Skill")
    func stableStoreAndCascade() throws {
        try withV11Database { connection in
            let skillID = SkillID()
            try insertV11TestSkill(skillID, slug: "before", connection: connection)
            let store = ManagedPublishStateStore(connection: connection)
            let first = SQLitePublishState(
                lastPublishedHash: "first",
                lastPublishedAtMilliseconds: 1,
                hashAlgorithmVersion: 1
            )
            try store.save(first, skillID: skillID)
            #expect(try store.load(skillID: skillID) == first)

            let rename = try connection.prepare(
                """
                UPDATE skills
                SET display_name = 'After', default_distribution_slug = 'after',
                    default_slug_key = 'after'
                WHERE skill_id = ?
                """
            )
            try rename.bind(skillID.bytes, at: 1)
            _ = try rename.step()
            #expect(try store.load(skillID: skillID) == first)

            let second = SQLitePublishState(
                lastPublishedHash: "second",
                lastPublishedAtMilliseconds: 2,
                hashAlgorithmVersion: 1
            )
            try store.save(second, skillID: skillID)
            #expect(try store.load(skillID: skillID) == second)
            #expect(throws: SQLiteStoreError.self) {
                try store.save(second, skillID: SkillID())
            }

            let delete = try connection.prepare("DELETE FROM skills WHERE skill_id = ?")
            try delete.bind(skillID.bytes, at: 1)
            _ = try delete.step()
            #expect(try store.load(skillID: skillID) == nil)
        }
    }

    @Test("slug and stored collision-key drift rolls migration back")
    func rejectsCorruptSlugKey() throws {
        try withV10Database { connection, _ in
            let skillID = SkillID()
            try insertV11TestSkill(skillID, slug: "valid", connection: connection)
            try connection.execute("UPDATE skills SET default_slug_key = 'wrong'")

            #expect(throws: SQLiteStoreError.self) {
                try SkillSchemaMigrator.migrateIfNeeded(connection)
            }
            #expect(try connection.querySingleInt("PRAGMA user_version") == 10)
            #expect(!(try connection.userTableNames()).contains("managed_publish_states"))
        }
    }

    @Test("save preserves a migrated source locator")
    func savePreservesMigrationSource() throws {
        try withV10Database { connection, _ in
            let skillID = SkillID()
            try insertV11TestSkill(skillID, slug: "source", connection: connection)
            try insertLegacyPublishState(
                locator: "skill-state/source.json",
                hash: "old",
                connection: connection
            )
            try SkillSchemaMigrator.migrateIfNeeded(connection)
            try ManagedPublishStateStore(connection: connection).save(
                SQLitePublishState(
                    lastPublishedHash: "new",
                    lastPublishedAtMilliseconds: 20,
                    hashAlgorithmVersion: 1
                ),
                skillID: skillID
            )
            #expect(try connection.querySingleText(
                "SELECT source_runtime_locator FROM managed_publish_states"
            ) == "skill-state/source.json")
            #expect(throws: SQLiteStoreError.self) {
                try connection.execute(
                    "UPDATE managed_publish_states SET source_runtime_locator = NULL"
                )
            }
            #expect(throws: SQLiteStoreError.self) {
                try connection.execute(
                    "UPDATE managed_publish_states SET skill_id = zeroblob(16)"
                )
            }
        }
    }
}

private func withV10Database(
    _ body: (SQLiteConnection, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v11-v10-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("manager.sqlite")
    let connection = try SQLiteConnection(url: databaseURL)
    for statement in SkillSchemaV1.statements { try connection.execute(statement) }
    try connection.execute(
        "INSERT INTO schema_metadata(singleton, schema_version) VALUES (1, 10)"
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
        SkillSchemaV10.statements,
    ] {
        for statement in statements { try connection.execute(statement) }
    }
    try connection.execute("PRAGMA user_version = 10")
    try body(connection, databaseURL)
}

private func deleteV11Skill(
    _ skillID: SkillID,
    connection: SQLiteConnection
) throws {
    let journal = try SSOTJournalStore(connection: connection)
    guard let expected = try journal.storedDomain(skillID) else {
        throw SQLiteStoreError.invalidState("missing v11 deletion fixture")
    }
    try connection.withImmediateTransaction {
        try journal.deleteDomainInCurrentTransaction(
            skillID: skillID,
            expected: expected
        )
    }
}

private func withV11Database(_ body: (SQLiteConnection) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skill-schema-v11-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(try SkillSchemaMigrator.open(at: root.appendingPathComponent("manager.sqlite")))
}

private func insertV11TestSkill(
    _ skillID: SkillID,
    slug: String,
    connection: SQLiteConnection
) throws {
    let statement = try connection.prepare(
        """
        INSERT INTO skills(
          skill_id, display_name, default_distribution_slug, default_slug_key,
          fingerprint_algorithm_version, content_fingerprint, status,
          created_at_ms, updated_at_ms, db_revision
        ) VALUES (?, ?, ?, ?, 1, zeroblob(32), 'managed', 1, 1, 0)
        """
    )
    try statement.bind(skillID.bytes, at: 1)
    try statement.bind(slug, at: 2)
    try statement.bind(slug, at: 3)
    try statement.bind(SkillContentPath.collisionKey(for: slug), at: 4)
    _ = try statement.step()
}

private func insertLegacyPublishState(
    locator: String,
    hash: String,
    connection: SQLiteConnection
) throws {
    let legacy = try connection.prepare(
        """
        INSERT INTO legacy_publish_states(
          legacy_locator, legacy_format_version, file_digest, last_published_hash,
          last_published_at_ms, hash_algorithm_version, binding_status,
          bound_skill_id, bound_at_ms, migrated_at_ms
        ) VALUES (?, 0, zeroblob(32), ?, 10, 1, 'unresolved', NULL, NULL, 5)
        """
    )
    try legacy.bind(locator, at: 1)
    try legacy.bind(hash, at: 2)
    _ = try legacy.step()

    let runtime = try connection.prepare(
        """
        INSERT INTO publish_states(
          runtime_locator, source_legacy_locator, last_published_hash,
          last_published_at_ms, hash_algorithm_version
        ) VALUES (?, ?, ?, 10, 1)
        """
    )
    try runtime.bind(locator, at: 1)
    try runtime.bind(locator, at: 2)
    try runtime.bind(hash, at: 3)
    _ = try runtime.step()
}
