import Foundation

typealias SkillUpdateCheckStatus = ManagedSkillUpdateCheckStatus

nonisolated enum UpdateCheckStoreError: Error, Equatable, LocalizedError {
    case invalidRecord
    case corruptRecord
    case conflict

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "The Skill update check record is invalid."
        case .corruptRecord: "The Skill update check record is corrupt."
        case .conflict: "The Skill update check record changed concurrently."
        }
    }
}

nonisolated struct StoredSkillUpdateCheck: Equatable, Sendable {
    static let maximumPayloadBytes = 65_536

    let skillID: SkillID
    let status: SkillUpdateCheckStatus
    let checkedAtMilliseconds: Int64
    let payload: Data

    init(
        skillID: SkillID,
        status: SkillUpdateCheckStatus,
        checkedAtMilliseconds: Int64,
        payload: Data
    ) throws {
        guard checkedAtMilliseconds >= 0,
              (1...Self.maximumPayloadBytes).contains(payload.count) else {
            throw UpdateCheckStoreError.invalidRecord
        }
        self.skillID = skillID
        self.status = status
        self.checkedAtMilliseconds = checkedAtMilliseconds
        self.payload = payload
    }
}

nonisolated struct UpdateCheckStore {
    private static let formatVersion: Int64 = 1
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func load(skillID: SkillID) throws -> StoredSkillUpdateCheck? {
        let statement = try connection.prepare(
            """
            SELECT skill_id, format_version, status, checked_at_ms, snapshot_payload
            FROM skill_update_checks
            WHERE skill_id = ?
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        guard try statement.step() else { return nil }
        let record = try decode(statement)
        guard record.skillID == skillID, try !statement.step() else {
            throw UpdateCheckStoreError.corruptRecord
        }
        return record
    }

    func upsert(_ record: StoredSkillUpdateCheck) throws {
        try transaction {
            try upsertInCurrentTransaction(record)
        }
    }

    func upsertInCurrentTransaction(_ record: StoredSkillUpdateCheck) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO skill_update_checks(
              skill_id, format_version, status, checked_at_ms, snapshot_payload
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(skill_id) DO UPDATE SET
              format_version = excluded.format_version,
              status = excluded.status,
              checked_at_ms = excluded.checked_at_ms,
              snapshot_payload = excluded.snapshot_payload
            """
        )
        try statement.bind(record.skillID.bytes, at: 1)
        try statement.bind(Self.formatVersion, at: 2)
        try statement.bind(record.status.rawValue, at: 3)
        try statement.bind(record.checkedAtMilliseconds, at: 4)
        try statement.bind(record.payload, at: 5)
        guard try !statement.step(),
              try connection.querySingleInt("SELECT changes()") == 1,
              try load(skillID: record.skillID) == record else {
            throw UpdateCheckStoreError.conflict
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try connection.withImmediateTransaction(body)
    }

    private func decode(_ statement: SQLiteStatement) throws -> StoredSkillUpdateCheck {
        do {
            guard let skillIDBytes = statement.blob(at: 0),
                  statement.int64(at: 1) == Self.formatVersion,
                  let rawStatus = statement.text(at: 2),
                  let status = SkillUpdateCheckStatus(rawValue: rawStatus),
                  let payload = statement.blob(at: 4) else {
                throw UpdateCheckStoreError.corruptRecord
            }
            return try StoredSkillUpdateCheck(
                skillID: SkillID(bytes: skillIDBytes),
                status: status,
                checkedAtMilliseconds: statement.int64(at: 3),
                payload: payload
            )
        } catch let error as UpdateCheckStoreError {
            if error == .invalidRecord { throw UpdateCheckStoreError.corruptRecord }
            throw error
        } catch {
            throw UpdateCheckStoreError.corruptRecord
        }
    }
}
