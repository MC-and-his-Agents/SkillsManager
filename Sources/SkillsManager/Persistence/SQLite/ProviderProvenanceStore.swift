import Foundation

nonisolated struct ProviderProvenanceStore {
    let connection: SQLiteConnection

    func load(skillID: SkillID) throws -> [ProviderProvenanceRecord] {
        let statement = try connection.prepare(
            """
            SELECT provider, provider_identifier, provider_identifier_key, provider_version
            FROM provider_provenance
            WHERE skill_id = ?
            ORDER BY provider, provider_identifier_key
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        var records: [ProviderProvenanceRecord] = []
        while try statement.step() {
            records.append(try record(statement, skillID: skillID))
        }
        return records
    }

    func load(identity: ProviderAliasIdentity) throws -> ProviderProvenanceRecord? {
        let slug = try DefaultDistributionSlug(validating: identity.identifier)
        let statement = try connection.prepare(
            """
            SELECT skill_id, provider, provider_identifier, provider_identifier_key,
                   provider_version
            FROM provider_provenance
            WHERE provider = ? AND provider_identifier_key = ?
            """
        )
        try statement.bind(identity.provider, at: 1)
        try statement.bind(slug.collisionKey, at: 2)
        guard try statement.step() else { return nil }
        let skillID = try SkillID(bytes: requiredBlob(statement, 0))
        let result = try record(statement, skillID: skillID, offset: 1)
        guard try !statement.step() else {
            throw SSOTJournalStoreError.corruptRecord("duplicate provider provenance locator")
        }
        return result
    }

    func replace(skillID: SkillID, records: [ProviderProvenanceRecord]) throws {
        let delete = try connection.prepare(
            "DELETE FROM provider_provenance WHERE skill_id = ?"
        )
        try delete.bind(skillID.bytes, at: 1)
        guard try !delete.step() else {
            throw SSOTJournalStoreError.databaseConflict
        }
        for record in records {
            let insert = try connection.prepare(
                """
                INSERT INTO provider_provenance(
                  skill_id, provider, provider_identifier, provider_identifier_key,
                  provider_version
                ) VALUES (?, ?, ?, ?, ?)
                """
            )
            try insert.bind(record.skillID.bytes, at: 1)
            try insert.bind(record.identity.provider, at: 2)
            try insert.bind(record.identity.identifier, at: 3)
            try insert.bind(record.identifierKey, at: 4)
            if let version = record.version?.value {
                try insert.bind(version, at: 5)
            } else {
                try insert.bindNull(at: 5)
            }
            guard try !insert.step(),
                  try connection.querySingleInt("SELECT changes()") == 1 else {
                throw SSOTJournalStoreError.databaseConflict
            }
        }
    }

    private func record(
        _ statement: SQLiteStatement,
        skillID: SkillID,
        offset: Int32 = 0
    ) throws -> ProviderProvenanceRecord {
        do {
            return try ProviderProvenanceRecord(
                skillID: skillID,
                identity: ProviderAliasIdentity(
                    provider: requiredText(statement, offset),
                    identifier: requiredText(statement, offset + 1)
                ),
                identifierKey: requiredText(statement, offset + 2),
                version: try statement.text(at: offset + 3).map(SourceVersion.init)
            )
        } catch {
            throw SSOTJournalStoreError.corruptRecord("stored provider provenance is invalid")
        }
    }

    private func requiredText(_ statement: SQLiteStatement, _ column: Int32) throws -> String {
        guard let value = statement.text(at: column) else {
            throw SSOTJournalStoreError.corruptRecord("provider provenance text is NULL")
        }
        return value
    }

    private func requiredBlob(_ statement: SQLiteStatement, _ column: Int32) throws -> Data {
        guard let value = statement.blob(at: column) else {
            throw SSOTJournalStoreError.corruptRecord("provider provenance Skill ID is NULL")
        }
        return value
    }
}
