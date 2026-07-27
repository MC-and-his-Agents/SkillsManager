import Foundation

nonisolated struct SQLitePublishState: Equatable, Sendable {
    let lastPublishedHash: String
    let lastPublishedAtMilliseconds: Int64
    let hashAlgorithmVersion: Int?
}

nonisolated struct ManagedPublishStateStore {
    let connection: SQLiteConnection

    func load(skillID: SkillID) throws -> SQLitePublishState? {
        let statement = try connection.prepare(
            """
            SELECT last_published_hash, last_published_at_ms, hash_algorithm_version
            FROM managed_publish_states WHERE skill_id = ?
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        guard try statement.step(),
              let hash = statement.text(at: 0),
              !statement.isNull(at: 1) else {
            return nil
        }
        let state = SQLitePublishState(
            lastPublishedHash: hash,
            lastPublishedAtMilliseconds: statement.int64(at: 1),
            hashAlgorithmVersion: statement.isNull(at: 2) ? nil : Int(statement.int64(at: 2))
        )
        guard try !statement.step() else {
            throw SQLiteStoreError.invalidState("duplicate managed publish state")
        }
        return state
    }

    func save(_ state: SQLitePublishState, skillID: SkillID) throws {
        guard 1...512 ~= state.lastPublishedHash.utf8.count,
              state.hashAlgorithmVersion == 1 else {
            throw SQLiteStoreError.invalidState("managed publish state is invalid")
        }
        let statement = try connection.prepare(
            """
            INSERT INTO managed_publish_states(
              skill_id, source_runtime_locator, last_published_hash,
              last_published_at_ms, hash_algorithm_version
            ) VALUES (?, NULL, ?, ?, ?)
            ON CONFLICT(skill_id) DO UPDATE SET
              last_published_hash = excluded.last_published_hash,
              last_published_at_ms = excluded.last_published_at_ms,
              hash_algorithm_version = excluded.hash_algorithm_version
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        try statement.bind(state.lastPublishedHash, at: 2)
        try statement.bind(state.lastPublishedAtMilliseconds, at: 3)
        try statement.bind(Int64(1), at: 4)
        _ = try statement.step()
    }
}
