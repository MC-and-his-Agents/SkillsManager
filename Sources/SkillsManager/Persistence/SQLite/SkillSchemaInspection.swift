import CryptoKit
import Foundation

nonisolated enum SkillSchemaInspection {
    static func schemaFingerprint(
        _ connection: SQLiteConnection,
        objectNames: [String]
    ) throws -> Data {
        let statement = try connection.prepare(
            "SELECT name, sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name"
        )
        let expectedNames = Set(objectNames)
        var entries: [(name: String, sql: String)] = []
        while try statement.step() {
            guard let name = statement.text(at: 0), let sql = statement.text(at: 1) else {
                throw SQLiteStoreError.invalidState("sqlite_schema returned NULL SQL")
            }
            if expectedNames.contains(name) {
                entries.append((name, canonicalSchemaSQL(sql)))
            }
        }
        guard entries.map(\.name) == objectNames else {
            throw SQLiteStoreError.invalidState("schema fingerprint objects do not match")
        }
        return hashSchemaEntries(entries)
    }

    static func expectedV2SchemaFingerprint() throws -> Data {
        try expectedSchemaFingerprint(
            objectNames: SkillSchemaV2.fingerprintedObjectNames,
            statements: SkillSchemaV1.statements
                + SkillSchemaV2.statements
                + [SkillSchemaV2.expectedSkillsTableSQL],
            version: 2
        )
    }

    static func expectedV3SchemaFingerprint() throws -> Data {
        try expectedSchemaFingerprint(
            objectNames: SkillSchemaV3.fingerprintedObjectNames,
            statements: SkillSchemaV1.statements
                + SkillSchemaV2.statements
                + SkillSchemaV3.statements
                + [SkillSchemaV2.expectedSkillsTableSQL],
            version: 3
        )
    }

    static func expectedV4SchemaFingerprint() throws -> Data {
        try expectedSchemaFingerprint(
            objectNames: SkillSchemaV4.fingerprintedObjectNames,
            statements: SkillSchemaV1.statements
                + SkillSchemaV2.statements
                + SkillSchemaV3.statements
                + SkillSchemaV4.statements
                + [SkillSchemaV2.expectedSkillsTableSQL],
            version: 4
        )
    }

    static func expectedV5SchemaFingerprint() throws -> Data {
        try expectedSchemaFingerprint(
            objectNames: SkillSchemaV5.fingerprintedObjectNames,
            statements: SkillSchemaV1.statements
                + SkillSchemaV2.statements
                + SkillSchemaV3.statements
                + SkillSchemaV4.statements
                + SkillSchemaV5.statements
                + [SkillSchemaV2.expectedSkillsTableSQL],
            version: 5
        )
    }

    static func columnNames(
        _ connection: SQLiteConnection,
        table: String
    ) throws -> [String] {
        try textValues(connection, sql: "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid")
    }

    static func textValues(
        _ connection: SQLiteConnection,
        sql: String
    ) throws -> [String] {
        let statement = try connection.prepare(sql)
        var values: [String] = []
        while try statement.step() {
            guard let value = statement.text(at: 0) else {
                throw SQLiteStoreError.invalidState("schema query returned NULL text")
            }
            values.append(value)
        }
        return values
    }

    private static func expectedSchemaFingerprint(
        objectNames: [String],
        statements: [String],
        version: Int
    ) throws -> Data {
        let expectedNames = Set(objectNames)
        var sqlByName: [String: String] = [:]
        for statement in statements {
            let canonical = canonicalSchemaSQL(statement)
            guard let name = createdSchemaObjectName(canonical), expectedNames.contains(name) else {
                continue
            }
            sqlByName[name] = canonical
        }
        let entries = sqlByName.map { (name: $0.key, sql: $0.value) }
            .sorted { $0.name < $1.name }
        guard entries.map(\.name) == objectNames else {
            throw SQLiteStoreError.invalidState(
                "expected schema v\(version) fingerprint is incomplete"
            )
        }
        return hashSchemaEntries(entries)
    }

    private static func canonicalSchemaSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func createdSchemaObjectName(_ canonicalSQL: String) -> String? {
        let words = canonicalSQL.split(separator: " ")
        guard words.first == "CREATE", words.count >= 3 else { return nil }
        if words[1] == "UNIQUE" {
            guard words.count >= 4, words[2] == "INDEX" else { return nil }
            return String(words[3])
        }
        if words[1] == "INDEX" { return String(words[2]) }
        guard words[1] == "TABLE" || words[1] == "TRIGGER" else { return nil }
        return String(words[2])
    }

    private static func hashSchemaEntries(
        _ entries: [(name: String, sql: String)]
    ) -> Data {
        var bytes = Data()
        for entry in entries {
            bytes.append(contentsOf: entry.name.utf8)
            bytes.append(0)
            bytes.append(contentsOf: entry.sql.utf8)
            bytes.append(0)
        }
        return Data(SHA256.hash(data: bytes))
    }
}
