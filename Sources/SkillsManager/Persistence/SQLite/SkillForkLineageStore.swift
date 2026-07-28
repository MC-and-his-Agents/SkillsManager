import Foundation

nonisolated enum SkillForkLineageStoreError: Error, Equatable {
    case conflict
    case corruptRecord
}

nonisolated struct SkillForkLineageStore {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func load(skillID: SkillID) throws -> SkillForkLineageRecord? {
        let statement = try connection.prepare(
            """
            SELECT parent_skill_id, forked_from_algorithm_version,
                   forked_from_hash, created_at_ms, origin_type
            FROM skill_fork_lineage WHERE fork_skill_id = ?
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        guard try statement.step() else { return nil }
        guard let parentBytes = statement.blob(at: 0),
              let digest = statement.blob(at: 2),
              let origin = statement.text(at: 4),
              let originType = SkillForkOriginType(rawValue: origin) else {
            throw SkillForkLineageStoreError.corruptRecord
        }
        let record: SkillForkLineageRecord
        do {
            record = try SkillForkLineageRecord(
                forkSkillID: skillID,
                parentSkillID: SkillID(bytes: parentBytes),
                forkedFromFingerprint: SkillContentFingerprint(
                    algorithmVersion: Int(statement.int64(at: 1)),
                    digest: digest
                ),
                createdAtMilliseconds: statement.int64(at: 3),
                originType: originType
            )
        } catch {
            throw SkillForkLineageStoreError.corruptRecord
        }
        guard try !statement.step() else {
            throw SkillForkLineageStoreError.corruptRecord
        }
        return record
    }

    func insertInCurrentTransaction(_ lineage: SkillForkLineageRecord?) throws {
        guard let lineage else { return }
        guard try load(skillID: lineage.forkSkillID) == nil else {
            throw SkillForkLineageStoreError.conflict
        }
        try insert(lineage)
    }

    func requireUnchangedInCurrentTransaction(
        skillID: SkillID,
        lineage: SkillForkLineageRecord?
    ) throws {
        guard try load(skillID: skillID) == lineage else {
            throw SkillForkLineageStoreError.conflict
        }
    }

    private func insert(_ lineage: SkillForkLineageRecord) throws {
        let insert = try connection.prepare(
            """
            INSERT INTO skill_fork_lineage(
              fork_skill_id, parent_skill_id,
              forked_from_algorithm_version, forked_from_hash,
              created_at_ms, origin_type
            ) VALUES (?, ?, ?, ?, ?, ?)
            """
        )
        try insert.bind(lineage.forkSkillID.bytes, at: 1)
        try insert.bind(lineage.parentSkillID.bytes, at: 2)
        try insert.bind(Int64(lineage.forkedFromFingerprint.algorithmVersion), at: 3)
        try insert.bind(lineage.forkedFromFingerprint.digest, at: 4)
        try insert.bind(lineage.createdAtMilliseconds, at: 5)
        try insert.bind(lineage.originType.rawValue, at: 6)
        guard try !insert.step(),
              try connection.querySingleInt("SELECT changes()") == 1 else {
            throw SkillForkLineageStoreError.conflict
        }
    }
}
