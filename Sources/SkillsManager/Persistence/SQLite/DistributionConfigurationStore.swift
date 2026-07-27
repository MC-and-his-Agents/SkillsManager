import Foundation

nonisolated enum DistributionConfigurationStoreError: Error, Equatable {
    case conflict
    case invalidInput
}

/// Row presence distinguishes an explicit empty selection from an unconfigured Skill.
nonisolated struct DistributionConfigurationStore {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func load(skillID: SkillID) throws -> Bool {
        let statement = try connection.prepare(
            "SELECT 1 FROM distribution_configurations WHERE skill_id = ?"
        )
        try statement.bind(skillID.bytes, at: 1)
        return try statement.step()
    }

    func replaceInCurrentTransaction(
        skillID: SkillID,
        expectedOld: Bool,
        desired: Bool,
        nowMilliseconds: Int64
    ) throws {
        guard nowMilliseconds >= 0 else {
            throw DistributionConfigurationStoreError.invalidInput
        }
        let actual = try load(skillID: skillID)
        guard actual == expectedOld else {
            throw DistributionConfigurationStoreError.conflict
        }
        guard actual != desired else { return }

        if desired {
            let statement = try connection.prepare(
                """
                INSERT INTO distribution_configurations(skill_id, configured_at_ms)
                VALUES (?, ?)
                """
            )
            try statement.bind(skillID.bytes, at: 1)
            try statement.bind(nowMilliseconds, at: 2)
            guard try !statement.step(),
                  try connection.querySingleInt("SELECT changes()") == 1 else {
                throw DistributionConfigurationStoreError.conflict
            }
        } else {
            let statement = try connection.prepare(
                "DELETE FROM distribution_configurations WHERE skill_id = ?"
            )
            try statement.bind(skillID.bytes, at: 1)
            guard try !statement.step(),
                  try connection.querySingleInt("SELECT changes()") == 1 else {
                throw DistributionConfigurationStoreError.conflict
            }
        }
    }
}
