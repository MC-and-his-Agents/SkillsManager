import Foundation

nonisolated struct SQLiteCustomPathRecord: Equatable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let addedAtMilliseconds: Int64
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
                SELECT custom_path_id, absolute_url, normalized_url_key, display_name, added_at_ms
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
                      !statement.isNull(at: 4) else {
                    throw LegacyMigrationFailure(.ledgerConflict)
                }
                records.append(SQLiteCustomPathRecord(
                    id: try catalogUUID(from: idBytes),
                    url: url,
                    displayName: displayName,
                    addedAtMilliseconds: statement.int64(at: 4)
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
                  custom_path_id, absolute_url, normalized_url_key, display_name, added_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                """
            )
            try statement.bind(catalogUUIDBytes(path.id), at: 1)
            try statement.bind(normalized.absoluteURL, at: 2)
            try statement.bind(normalized.key, at: 3)
            try statement.bind(path.displayName, at: 4)
            try statement.bind(milliseconds, at: 5)
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

nonisolated struct SQLitePublishState: Equatable, Sendable {
    let lastPublishedHash: String
    let lastPublishedAtMilliseconds: Int64
    let hashAlgorithmVersion: Int?
}

nonisolated final class SQLitePublishStatePersistence {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) throws {
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
        self.connection = connection
    }

    func load(forSlug slug: String) throws -> SQLitePublishState? {
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
        let locator = try PublishStateLocator.fromSlug(slug)
        do {
            let statement = try connection.prepare(
                """
                SELECT last_published_hash, last_published_at_ms, hash_algorithm_version
                FROM publish_states WHERE runtime_locator = ?
                """
            )
            try statement.bind(locator, at: 1)
            guard try statement.step() else { return nil }
            guard let hash = statement.text(at: 0), !statement.isNull(at: 1) else {
                throw LegacyMigrationFailure(.ledgerConflict)
            }
            let state = SQLitePublishState(
                lastPublishedHash: hash,
                lastPublishedAtMilliseconds: statement.int64(at: 1),
                hashAlgorithmVersion: statement.isNull(at: 2) ? nil : Int(statement.int64(at: 2))
            )
            guard try !statement.step() else { throw LegacyMigrationFailure(.ledgerConflict) }
            return state
        } catch {
            throw mapLegacySQLiteError(error, invalidCode: .ledgerConflict)
        }
    }

    func save(_ state: SQLitePublishState, forSlug slug: String) throws {
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
        let locator = try PublishStateLocator.fromSlug(slug)
        guard 1...512 ~= state.lastPublishedHash.utf8.count,
              state.hashAlgorithmVersion == 1 else {
            throw LegacyMigrationFailure(.databaseFailure)
        }
        do {
            let statement = try connection.prepare(
                """
                INSERT INTO publish_states(
                  runtime_locator, source_legacy_locator, last_published_hash,
                  last_published_at_ms, hash_algorithm_version
                ) VALUES (?, NULL, ?, ?, ?)
                ON CONFLICT(runtime_locator) DO UPDATE SET
                  last_published_hash = excluded.last_published_hash,
                  last_published_at_ms = excluded.last_published_at_ms,
                  hash_algorithm_version = excluded.hash_algorithm_version
                """
            )
            try statement.bind(locator, at: 1)
            try statement.bind(state.lastPublishedHash, at: 2)
            try statement.bind(state.lastPublishedAtMilliseconds, at: 3)
            try bindOptionalRuntimeInt(state.hashAlgorithmVersion, to: statement, at: 4)
            guard try !statement.step() else { throw LegacyMigrationFailure(.databaseFailure) }
        } catch {
            throw mapLegacySQLiteError(error, invalidCode: .databaseFailure)
        }
    }
}

private nonisolated func runtimeMilliseconds(_ date: Date) throws -> Int64 {
    try LegacyDateCodec.milliseconds(from: date)
}

private nonisolated func bindOptionalRuntimeInt(
    _ value: Int?,
    to statement: SQLiteStatement,
    at index: Int32
) throws {
    if let value { try statement.bind(Int64(value), at: index) }
    else { try statement.bindNull(at: index) }
}
