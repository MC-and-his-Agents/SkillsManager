import Foundation
import SQLite3

nonisolated struct RepositoryCatalogStore {
    let connection: SQLiteConnection

    func list() throws -> [CustomRepositoryCatalogRecord] {
        let statement = try connection.prepare(selectSQL + " ORDER BY normalized_repository_url")
        var records: [CustomRepositoryCatalogRecord] = []
        while try statement.step() { records.append(try record(statement)) }
        return records
    }

    func load(id: UUID) throws -> CustomRepositoryCatalogRecord? {
        let statement = try connection.prepare(selectSQL + " WHERE repository_id = ?")
        try statement.bind(catalogUUIDBytes(id), at: 1)
        guard try statement.step() else { return nil }
        let value = try record(statement)
        guard try !statement.step() else { throw CustomRepositoryCatalogError.corruptRecord }
        return value
    }

    func insert(
        _ input: CustomRepositoryCatalogInput,
        id: UUID = UUID(),
        nowMilliseconds: Int64
    ) throws -> CustomRepositoryCatalogRecord {
        guard nowMilliseconds >= 0 else { throw CustomRepositoryCatalogError.corruptRecord }
        let statement = try connection.prepare(
            """
            INSERT INTO repository_catalog(
              repository_id, normalized_repository_url, ref_kind, requested_ref,
              display_name, enabled, created_at_ms, updated_at_ms, db_revision
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
            """
        )
        try bind(input, id: id, nowMilliseconds: nowMilliseconds, to: statement)
        do {
            guard try !statement.step() else { throw CustomRepositoryCatalogError.corruptRecord }
        } catch let error as SQLiteStoreError {
            if case .sqlite(_, let code, _) = error,
               code & 0xff == SQLITE_CONSTRAINT {
                throw CustomRepositoryCatalogError.alreadyExists
            }
            throw error
        }
        return try required(id: id)
    }

    func replace(
        id: UUID,
        expectedRevision: Int64,
        input: CustomRepositoryCatalogInput,
        nowMilliseconds: Int64
    ) throws -> CustomRepositoryCatalogRecord {
        guard expectedRevision >= 0, expectedRevision < Int64.max, nowMilliseconds >= 0 else {
            throw CustomRepositoryCatalogError.conflict
        }
        guard let current = try load(id: id) else { throw CustomRepositoryCatalogError.notFound }
        guard current.databaseRevision == expectedRevision,
              current.repositoryURL == input.repositoryURL else {
            throw CustomRepositoryCatalogError.conflict
        }
        let statement = try connection.prepare(
            """
            UPDATE repository_catalog SET ref_kind = ?, requested_ref = ?, display_name = ?,
              enabled = ?, updated_at_ms = ?, db_revision = db_revision + 1
            WHERE repository_id = ? AND db_revision = ?
            """
        )
        try bind(ref: input.requestedRef, to: statement, startingAt: 1)
        try statement.bind(input.displayName, at: 3)
        try statement.bind(input.enabled ? 1 : 0, at: 4)
        try statement.bind(max(nowMilliseconds, current.updatedAtMilliseconds), at: 5)
        try statement.bind(catalogUUIDBytes(id), at: 6)
        try statement.bind(expectedRevision, at: 7)
        guard try !statement.step(), try connection.querySingleInt("SELECT changes()") == 1 else {
            throw CustomRepositoryCatalogError.conflict
        }
        return try required(id: id)
    }

    func remove(id: UUID, expectedRevision: Int64) throws {
        guard let current = try load(id: id) else { throw CustomRepositoryCatalogError.notFound }
        guard current.databaseRevision == expectedRevision else {
            throw CustomRepositoryCatalogError.conflict
        }
        let statement = try connection.prepare(
            "DELETE FROM repository_catalog WHERE repository_id = ? AND db_revision = ?"
        )
        try statement.bind(catalogUUIDBytes(id), at: 1)
        try statement.bind(expectedRevision, at: 2)
        guard try !statement.step(), try connection.querySingleInt("SELECT changes()") == 1 else {
            throw CustomRepositoryCatalogError.conflict
        }
    }

    private var selectSQL: String {
        """
        SELECT repository_id, normalized_repository_url, ref_kind, requested_ref,
          display_name, enabled, created_at_ms, updated_at_ms, db_revision
        FROM repository_catalog
        """
    }

    private func required(id: UUID) throws -> CustomRepositoryCatalogRecord {
        guard let value = try load(id: id) else { throw CustomRepositoryCatalogError.corruptRecord }
        return value
    }

    private func record(_ statement: SQLiteStatement) throws -> CustomRepositoryCatalogRecord {
        do {
            guard let id = statement.blob(at: 0),
                  let rawURL = statement.text(at: 1),
                  let kind = statement.text(at: 2),
                  let displayName = statement.text(at: 4),
                  !statement.isNull(at: 5), !statement.isNull(at: 6),
                  !statement.isNull(at: 7), !statement.isNull(at: 8) else {
                throw CustomRepositoryCatalogError.corruptRecord
            }
            let requestedRef: CustomRepositoryRef
            switch (kind, statement.text(at: 3)) {
            case ("defaultBranch", nil): requestedRef = .defaultBranch
            case ("explicit", .some(let value)):
                requestedRef = try .explicit(validating: value)
            default: throw CustomRepositoryCatalogError.corruptRecord
            }
            let url = try CustomRepositoryCatalogValidation.githubURL(rawURL)
            guard url.value == rawURL, statement.int64(at: 5) == 0 || statement.int64(at: 5) == 1 else {
                throw CustomRepositoryCatalogError.corruptRecord
            }
            try CustomRepositoryCatalogValidation.validate(displayName: displayName)
            let created = statement.int64(at: 6)
            let updated = statement.int64(at: 7)
            let revision = statement.int64(at: 8)
            guard created >= 0, updated >= created, revision >= 0 else {
                throw CustomRepositoryCatalogError.corruptRecord
            }
            return CustomRepositoryCatalogRecord(
                repositoryID: try catalogUUID(from: id),
                repositoryURL: url,
                requestedRef: requestedRef,
                displayName: displayName,
                enabled: statement.int64(at: 5) == 1,
                createdAtMilliseconds: created,
                updatedAtMilliseconds: updated,
                databaseRevision: revision
            )
        } catch let error as CustomRepositoryCatalogError { throw error }
        catch { throw CustomRepositoryCatalogError.corruptRecord }
    }

    private func bind(
        _ input: CustomRepositoryCatalogInput,
        id: UUID,
        nowMilliseconds: Int64,
        to statement: SQLiteStatement
    ) throws {
        try statement.bind(catalogUUIDBytes(id), at: 1)
        try statement.bind(input.repositoryURL.value, at: 2)
        try bind(ref: input.requestedRef, to: statement, startingAt: 3)
        try statement.bind(input.displayName, at: 5)
        try statement.bind(input.enabled ? 1 : 0, at: 6)
        try statement.bind(nowMilliseconds, at: 7)
        try statement.bind(nowMilliseconds, at: 8)
    }

    private func bind(
        ref: CustomRepositoryRef,
        to statement: SQLiteStatement,
        startingAt index: Int32
    ) throws {
        switch ref {
        case .defaultBranch:
            try statement.bind("defaultBranch", at: index)
            try statement.bindNull(at: index + 1)
        case .explicit(let value):
            let normalized = try CustomRepositoryRef.explicit(validating: value)
            guard normalized == ref else { throw CustomRepositoryCatalogError.invalidRef }
            try statement.bind("explicit", at: index)
            try statement.bind(value, at: index + 1)
        }
    }
}
