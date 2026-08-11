import Foundation

nonisolated struct SQLiteCustomPathRecord: Equatable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let addedAtMilliseconds: Int64
    let mode: CustomSkillPathMode
}

nonisolated final class SQLiteCustomPathPersistence {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) throws {
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
        self.connection = connection
    }

    func loadAll() throws -> [SQLiteCustomPathRecord] {
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
        do {
            let statement = try connection.prepare(
                """
                SELECT custom_path_id, absolute_url, normalized_url_key, display_name, added_at_ms,
                       root_mode, adapter_code
                FROM custom_paths ORDER BY added_at_ms, custom_path_id
                """
            )
            var records: [SQLiteCustomPathRecord] = []
            while try statement.step() {
                guard let idBytes = statement.blob(at: 0),
                      let absoluteURL = statement.text(at: 1),
                      let normalizedKey = statement.blob(at: 2),
                      let normalized = try? LegacyCustomPathURLNormalizer.normalize(absoluteURL),
                      normalized.absoluteURL == absoluteURL,
                      normalized.key == normalizedKey,
                      let url = URL(string: absoluteURL),
                      let displayName = statement.text(at: 3),
                      !statement.isNull(at: 4),
                      let rootMode = statement.text(at: 5) else {
                    throw LegacyMigrationFailure(.ledgerConflict)
                }
                let mode: CustomSkillPathMode
                do {
                    mode = try CustomSkillPathMode(
                        storageKey: rootMode,
                        adapterCode: statement.text(at: 6)
                    )
                } catch {
                    throw LegacyMigrationFailure(.ledgerConflict)
                }
                records.append(SQLiteCustomPathRecord(
                    id: try catalogUUID(from: idBytes),
                    url: url,
                    displayName: displayName,
                    addedAtMilliseconds: statement.int64(at: 4),
                    mode: mode
                ))
            }
            return records
        } catch {
            throw mapLegacySQLiteError(error, invalidCode: .ledgerConflict)
        }
    }

    func insert(_ path: CustomSkillPath) throws {
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
        let normalized = try LegacyCustomPathURLNormalizer.normalize(path.url.absoluteString)
        let milliseconds = try runtimeMilliseconds(path.addedAt)
        do {
            let statement = try connection.prepare(
                """
                INSERT INTO custom_paths(
                  custom_path_id, absolute_url, normalized_url_key, display_name, added_at_ms,
                  root_mode, adapter_code
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            try statement.bind(catalogUUIDBytes(path.id), at: 1)
            try statement.bind(normalized.absoluteURL, at: 2)
            try statement.bind(normalized.key, at: 3)
            try statement.bind(path.displayName, at: 4)
            try statement.bind(milliseconds, at: 5)
            try statement.bind(path.mode.storageKey, at: 6)
            if let adapter = path.mode.adapter {
                try statement.bind(adapter.storageKey, at: 7)
            } else {
                try statement.bindNull(at: 7)
            }
            guard try !statement.step() else { throw LegacyMigrationFailure(.databaseFailure) }
        } catch {
            throw mapLegacySQLiteError(error, invalidCode: .databaseFailure)
        }
    }

    func remove(id: UUID) throws {
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
        do {
            let statement = try connection.prepare("DELETE FROM custom_paths WHERE custom_path_id = ?")
            try statement.bind(catalogUUIDBytes(id), at: 1)
            guard try !statement.step() else { throw LegacyMigrationFailure(.databaseFailure) }
        } catch {
            throw mapLegacySQLiteError(error, invalidCode: .databaseFailure)
        }
    }
}

private nonisolated func runtimeMilliseconds(_ date: Date) throws -> Int64 {
    try LegacyDateCodec.milliseconds(from: date)
}
