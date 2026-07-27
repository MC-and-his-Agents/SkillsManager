import Foundation

nonisolated enum SkillBackupStoreError: Error, Equatable, LocalizedError {
    case invalidRecord
    case conflict
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The Skill backup record is invalid."
        case .conflict: "The Skill backup changed concurrently."
        case .corruptRecord: "The Skill backup record is corrupt."
        }
    }
}

nonisolated final class SkillBackupStore {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) throws {
        guard connection.accessMode != .readOnly else {
            throw SQLiteStoreError.invalidState("the Skill backup store requires read-write access")
        }
        self.connection = connection
    }

    func insertPreparing(_ record: SkillBackupRecord) throws {
        guard record.state == .preparing else {
            throw SkillBackupStoreError.invalidRecord
        }
        let statement = try connection.prepare(
            """
            INSERT INTO skill_backups(
              backup_id, format_version, original_skill_id, state, locator,
              directory_identity, manifest_digest, fingerprint_algorithm_version,
              content_fingerprint, pinned, restored_skill_id, restore_result_json,
              prune_quarantine_locator, prune_quarantine_identity, last_error,
              created_at_ms, updated_at_ms
            ) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try bind(record, to: statement)
        do {
            try finishExactlyOne(statement)
        } catch let error as SkillBackupStoreError {
            throw error
        } catch {
            throw SkillBackupStoreError.conflict
        }
    }

    func load(_ backupID: SkillBackupID) throws -> SkillBackupRecord? {
        let statement = try connection.prepare(Self.selectSQL + " AND backup_id = ?")
        try statement.bind(backupID.bytes, at: 1)
        guard try statement.step() else { return nil }
        let record = try decode(statement)
        guard try !statement.step() else { throw SkillBackupStoreError.corruptRecord }
        return record
    }

    func list(originalSkillID: SkillID) throws -> [SkillBackupRecord] {
        let statement = try connection.prepare(
            Self.selectSQL
                + " AND original_skill_id = ? ORDER BY created_at_ms DESC, backup_id"
        )
        try statement.bind(originalSkillID.bytes, at: 1)
        var records: [SkillBackupRecord] = []
        while try statement.step() { records.append(try decode(statement)) }
        return records
    }

    func list() throws -> [SkillBackupRecord] {
        let statement = try connection.prepare(
            Self.selectSQL + " ORDER BY created_at_ms DESC, backup_id"
        )
        var records: [SkillBackupRecord] = []
        while try statement.step() { records.append(try decode(statement)) }
        return records
    }

    func recoverable() throws -> [SkillBackupRecord] {
        let statement = try connection.prepare(
            Self.selectSQL
                + " AND state IN ('preparing', 'pruning', 'needsRepair') "
                + "ORDER BY created_at_ms, backup_id"
        )
        var records: [SkillBackupRecord] = []
        while try statement.step() { records.append(try decode(statement)) }
        return records
    }

    func independentPreparing() throws -> [SkillBackupRecord] {
        let statement = try connection.prepare(
            Self.selectSQL
                + " AND state = 'preparing'"
                + " AND NOT EXISTS ("
                + "SELECT 1 FROM skill_deletion_operations AS deletion "
                + "WHERE deletion.backup_id = skill_backups.backup_id"
                + ") ORDER BY created_at_ms, backup_id"
        )
        var records: [SkillBackupRecord] = []
        while try statement.step() { records.append(try decode(statement)) }
        return records
    }

    func replace(
        expected old: SkillBackupRecord,
        with replacement: SkillBackupRecord
    ) throws {
        try connection.withImmediateTransaction {
            try replaceInCurrentTransaction(expected: old, with: replacement)
        }
    }

    func replaceInCurrentTransaction(
        expected old: SkillBackupRecord,
        with replacement: SkillBackupRecord
    ) throws {
        do {
            try replacement.validateTransition(from: old)
        } catch {
            throw SkillBackupStoreError.invalidRecord
        }
        guard old != replacement else { return }
        guard try load(old.backupID) == old else {
            throw SkillBackupStoreError.conflict
        }
        let statement = try connection.prepare(
                """
                UPDATE skill_backups
                SET state = ?, pinned = ?, restored_skill_id = ?, restore_result_json = ?,
                    prune_quarantine_locator = ?, prune_quarantine_identity = ?,
                    last_error = ?, updated_at_ms = ?
                WHERE backup_id = ? AND state = ? AND updated_at_ms = ?
                """
        )
        try statement.bind(replacement.state.rawValue, at: 1)
        try statement.bind(replacement.isPinned ? Int64(1) : Int64(0), at: 2)
        try bindOptional(replacement.restoredSkillID?.bytes, to: statement, at: 3)
        try bindOptional(replacement.restoreResultJSON, to: statement, at: 4)
        try bindOptional(replacement.pruneQuarantineLocator, to: statement, at: 5)
        try bindOptional(
            try replacement.pruneQuarantineIdentity.map {
                try ManagedItemIdentityCodec.encode($0)
            },
            to: statement,
            at: 6
        )
        try bindOptional(replacement.lastError, to: statement, at: 7)
        try statement.bind(replacement.updatedAtMilliseconds, at: 8)
        try statement.bind(old.backupID.bytes, at: 9)
        try statement.bind(old.state.rawValue, at: 10)
        try statement.bind(old.updatedAtMilliseconds, at: 11)
        try finishExactlyOne(statement)
    }

    func deletePruned(expected record: SkillBackupRecord) throws {
        guard record.state == .pruning else {
            throw SkillBackupStoreError.invalidRecord
        }
        try connection.withImmediateTransaction {
            try deleteInCurrentTransaction(expected: record)
        }
    }

    func deletePreparingInCurrentTransaction(
        expected record: SkillBackupRecord
    ) throws {
        guard record.state == .preparing else {
            throw SkillBackupStoreError.invalidRecord
        }
        try deleteInCurrentTransaction(expected: record)
    }

    private func deleteInCurrentTransaction(
        expected record: SkillBackupRecord
    ) throws {
        guard try load(record.backupID) == record else {
            throw SkillBackupStoreError.conflict
        }
        let statement = try connection.prepare(
            """
            DELETE FROM skill_backups
            WHERE backup_id = ? AND state = ? AND updated_at_ms = ?
            """
        )
        try statement.bind(record.backupID.bytes, at: 1)
        try statement.bind(record.state.rawValue, at: 2)
        try statement.bind(record.updatedAtMilliseconds, at: 3)
        try finishExactlyOne(statement)
    }

    private func bind(_ record: SkillBackupRecord, to statement: SQLiteStatement) throws {
        try statement.bind(record.backupID.bytes, at: 1)
        try statement.bind(record.originalSkillID.bytes, at: 2)
        try statement.bind(record.state.rawValue, at: 3)
        try statement.bind(record.locator, at: 4)
        try statement.bind(ManagedItemIdentityCodec.encode(record.directoryIdentity), at: 5)
        try statement.bind(record.manifestDigest, at: 6)
        try statement.bind(Int64(record.contentFingerprint.algorithmVersion), at: 7)
        try statement.bind(record.contentFingerprint.digest, at: 8)
        try statement.bind(record.isPinned ? Int64(1) : Int64(0), at: 9)
        try bindOptional(record.restoredSkillID?.bytes, to: statement, at: 10)
        try bindOptional(record.restoreResultJSON, to: statement, at: 11)
        try bindOptional(record.pruneQuarantineLocator, to: statement, at: 12)
        try bindOptional(
            try record.pruneQuarantineIdentity.map {
                try ManagedItemIdentityCodec.encode($0)
            },
            to: statement,
            at: 13
        )
        try bindOptional(record.lastError, to: statement, at: 14)
        try statement.bind(record.createdAtMilliseconds, at: 15)
        try statement.bind(record.updatedAtMilliseconds, at: 16)
    }

    private func decode(_ statement: SQLiteStatement) throws -> SkillBackupRecord {
        do {
            let state = try skillLifecycleRequiredEnum(
                statement, 3, as: SkillBackupState.self
            )
            let pinned = statement.int64(at: 9)
            guard pinned == 0 || pinned == 1 else {
                throw SkillBackupStoreError.corruptRecord
            }
            return try SkillBackupRecord(
                backupID: SkillBackupID(bytes: try skillLifecycleRequiredBlob(statement, 0)),
                originalSkillID: SkillID(bytes: try skillLifecycleRequiredBlob(statement, 2)),
                state: state,
                locator: try skillLifecycleRequiredText(statement, 4),
                directoryIdentity: try ManagedItemIdentityCodec.decode(
                    skillLifecycleRequiredBlob(statement, 5)
                ),
                manifestDigest: try skillLifecycleRequiredBlob(statement, 6),
                contentFingerprint: SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 7)),
                    digest: try skillLifecycleRequiredBlob(statement, 8)
                ),
                isPinned: pinned == 1,
                restoredSkillID: try statement.blob(at: 10).map(SkillID.init(bytes:)),
                restoreResultJSON: statement.blob(at: 11),
                pruneQuarantineLocator: statement.text(at: 12),
                pruneQuarantineIdentity: try statement.blob(at: 13)
                    .map(ManagedItemIdentityCodec.decode),
                lastError: statement.text(at: 14),
                createdAtMilliseconds: statement.int64(at: 15),
                updatedAtMilliseconds: statement.int64(at: 16)
            )
        } catch let error as SkillBackupStoreError {
            throw error
        } catch {
            throw SkillBackupStoreError.corruptRecord
        }
    }

    private func finishExactlyOne(_ statement: SQLiteStatement) throws {
        guard try !statement.step(),
              try connection.querySingleInt("SELECT changes()") == 1 else {
            throw SkillBackupStoreError.conflict
        }
    }

    private static let selectSQL = """
    SELECT backup_id, format_version, original_skill_id, state, locator,
           directory_identity, manifest_digest, fingerprint_algorithm_version,
           content_fingerprint, pinned, restored_skill_id, restore_result_json,
           prune_quarantine_locator, prune_quarantine_identity, last_error,
           created_at_ms, updated_at_ms
    FROM skill_backups
    WHERE format_version = 1
    """
}

nonisolated func skillLifecycleRequiredBlob(
    _ statement: SQLiteStatement,
    _ column: Int32
) throws -> Data {
    guard let value = statement.blob(at: column) else {
        throw SkillBackupStoreError.corruptRecord
    }
    return value
}

nonisolated func skillLifecycleRequiredText(
    _ statement: SQLiteStatement,
    _ column: Int32
) throws -> String {
    guard let value = statement.text(at: column) else {
        throw SkillBackupStoreError.corruptRecord
    }
    return value
}

nonisolated func skillLifecycleRequiredEnum<T: RawRepresentable>(
    _ statement: SQLiteStatement,
    _ column: Int32,
    as type: T.Type
) throws -> T where T.RawValue == String {
    guard let value = T(rawValue: try skillLifecycleRequiredText(statement, column)) else {
        throw SkillBackupStoreError.corruptRecord
    }
    return value
}

private nonisolated func bindOptional(
    _ value: Data?,
    to statement: SQLiteStatement,
    at index: Int32
) throws {
    if let value { try statement.bind(value, at: index) }
    else { try statement.bindNull(at: index) }
}

private nonisolated func bindOptional(
    _ value: String?,
    to statement: SQLiteStatement,
    at index: Int32
) throws {
    if let value { try statement.bind(value, at: index) }
    else { try statement.bindNull(at: index) }
}
