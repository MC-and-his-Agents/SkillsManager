import Foundation

nonisolated enum DistributionBindingStoreError: Error, Equatable {
    case conflict
    case corruptRecord
    case invalidInput
}

nonisolated struct DistributionBindingStore {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func load(skillID: SkillID) throws -> [DistributionBinding] {
        try loadBindings(skillID: skillID)
    }

    func replace(
        skillID: SkillID,
        expectedOld: [DistributionBinding],
        desired: [DistributionBindingIntent],
        nowMilliseconds: Int64
    ) throws -> [DistributionBinding] {
        return try connection.withImmediateTransaction {
            let actual = try loadBindings(skillID: skillID)
            guard canonical(expectedOld) == actual else {
                throw DistributionBindingStoreError.conflict
            }
            guard nowMilliseconds >= 0 else {
                throw DistributionBindingStoreError.invalidInput
            }
            let desired = try canonicalDesired(desired, skillID: skillID)
            guard actual.map(\.intent) != desired else { return actual }

            let actualByScope = Dictionary(
                uniqueKeysWithValues: actual.map { ($0.scope.targetScopeKey, $0) }
            )
            let desiredByScope = Dictionary(
                uniqueKeysWithValues: desired.map { ($0.scope.targetScopeKey, $0) }
            )
            let replacement = try desired.map { intent in
                if let old = actualByScope[intent.scope.targetScopeKey] {
                    guard old.intent != intent else { return old }
                    guard old.updatedAtMilliseconds < Int64.max else {
                        throw DistributionBindingStoreError.invalidInput
                    }
                    return try DistributionBinding(
                        skillID: intent.skillID,
                        scope: intent.scope,
                        distributionSlug: intent.distributionSlug,
                        syncMode: intent.syncMode,
                        createdAtMilliseconds: old.createdAtMilliseconds,
                        updatedAtMilliseconds: max(
                            nowMilliseconds,
                            old.updatedAtMilliseconds + 1
                        )
                    )
                }
                return try DistributionBinding(
                    skillID: intent.skillID,
                    scope: intent.scope,
                    distributionSlug: intent.distributionSlug,
                    syncMode: intent.syncMode,
                    createdAtMilliseconds: nowMilliseconds,
                    updatedAtMilliseconds: nowMilliseconds
                )
            }

            for binding in actual where desiredByScope[binding.scope.targetScopeKey] == nil {
                try delete(binding)
            }

            for binding in replacement {
                if let old = actualByScope[binding.scope.targetScopeKey] {
                    if old != binding {
                        try update(old, to: binding)
                    }
                } else {
                    try insert(binding)
                }
            }

            let readback = try loadBindings(skillID: skillID)
            guard readback == replacement else {
                throw DistributionBindingStoreError.conflict
            }
            return readback
        }
    }

    private func loadBindings(skillID: SkillID) throws -> [DistributionBinding] {
        let statement = try connection.prepare(
            """
            SELECT scope_kind, adapter_code, target_scope_key,
              distribution_slug, slug_key, sync_mode, created_at_ms, updated_at_ms
            FROM distribution_bindings WHERE skill_id = ?
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        var bindings: [DistributionBinding] = []
        while try statement.step() {
            bindings.append(try decode(statement, skillID: skillID))
        }
        return canonical(bindings)
    }

    private func decode(
        _ statement: SQLiteStatement,
        skillID: SkillID
    ) throws -> DistributionBinding {
        guard let scopeKind = statement.text(at: 0),
              let targetScopeKey = statement.text(at: 2),
              let slugValue = statement.text(at: 3),
              let slugKey = statement.text(at: 4),
              let syncValue = statement.text(at: 5),
              let syncMode = DistributionSyncMode(rawValue: syncValue) else {
            throw DistributionBindingStoreError.corruptRecord
        }
        let scope: DistributionBindingScope
        switch scopeKind {
        case "global":
            guard statement.isNull(at: 1) else {
                throw DistributionBindingStoreError.corruptRecord
            }
            scope = .global
        case "agent":
            guard let adapterCode = statement.text(at: 1),
                  let adapter = SkillPlatform.allCases.first(where: {
                      $0.storageKey == adapterCode
                  }) else {
                throw DistributionBindingStoreError.corruptRecord
            }
            scope = .agent(adapter)
        default:
            throw DistributionBindingStoreError.corruptRecord
        }
        do {
            let slug = try DefaultDistributionSlug(validating: slugValue)
            guard scope.targetScopeKey == targetScopeKey,
                  slug.collisionKey == slugKey else {
                throw DistributionBindingStoreError.corruptRecord
            }
            return try DistributionBinding(
                skillID: skillID,
                scope: scope,
                distributionSlug: slug,
                syncMode: syncMode,
                createdAtMilliseconds: statement.int64(at: 6),
                updatedAtMilliseconds: statement.int64(at: 7)
            )
        } catch let error as DistributionBindingStoreError {
            throw error
        } catch {
            throw DistributionBindingStoreError.corruptRecord
        }
    }

    private func canonicalDesired(
        _ desired: [DistributionBindingIntent],
        skillID: SkillID
    ) throws -> [DistributionBindingIntent] {
        guard desired.allSatisfy({ $0.skillID == skillID }) else {
            throw DistributionBindingStoreError.invalidInput
        }
        let scopeKeys = Set(desired.map(\.scope.targetScopeKey))
        guard scopeKeys.count == desired.count else {
            throw DistributionBindingStoreError.invalidInput
        }
        let globalCount = desired.count { $0.scope == .global }
        guard globalCount == 0 || (globalCount == 1 && desired.count == 1) else {
            throw DistributionBindingStoreError.invalidInput
        }
        return desired.sorted(by: distributionBindingIntentPrecedes)
    }

    private func canonical(_ bindings: [DistributionBinding]) -> [DistributionBinding] {
        bindings.sorted {
            distributionBindingIntentPrecedes($0.intent, $1.intent)
        }
    }

    private func delete(_ binding: DistributionBinding) throws {
        let statement = try connection.prepare(
            """
            DELETE FROM distribution_bindings
            WHERE skill_id = ? AND target_scope_key = ?
            """
        )
        try statement.bind(binding.skillID.bytes, at: 1)
        try statement.bind(binding.scope.targetScopeKey, at: 2)
        try finishExactlyOne(statement)
    }

    private func update(
        _ old: DistributionBinding,
        to binding: DistributionBinding
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE distribution_bindings
            SET distribution_slug = ?, slug_key = ?, sync_mode = ?, updated_at_ms = ?
            WHERE skill_id = ? AND target_scope_key = ?
            """
        )
        try statement.bind(binding.distributionSlug.value, at: 1)
        try statement.bind(binding.distributionSlug.collisionKey, at: 2)
        try statement.bind(binding.syncMode.rawValue, at: 3)
        try statement.bind(binding.updatedAtMilliseconds, at: 4)
        try statement.bind(binding.skillID.bytes, at: 5)
        try statement.bind(binding.scope.targetScopeKey, at: 6)
        try finishExactlyOne(statement)
    }

    private func insert(_ binding: DistributionBinding) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO distribution_bindings(
              skill_id, scope_kind, adapter_code, target_scope_key,
              distribution_slug, slug_key, sync_mode, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(binding.skillID.bytes, at: 1)
        try statement.bind(binding.scope.kind, at: 2)
        if let adapter = binding.scope.adapter {
            try statement.bind(adapter.storageKey, at: 3)
        } else {
            try statement.bindNull(at: 3)
        }
        try statement.bind(binding.scope.targetScopeKey, at: 4)
        try statement.bind(binding.distributionSlug.value, at: 5)
        try statement.bind(binding.distributionSlug.collisionKey, at: 6)
        try statement.bind(binding.syncMode.rawValue, at: 7)
        try statement.bind(binding.createdAtMilliseconds, at: 8)
        try statement.bind(binding.updatedAtMilliseconds, at: 9)
        try finishExactlyOne(statement)
    }

    private func finishExactlyOne(_ statement: SQLiteStatement) throws {
        guard try !statement.step(),
              try connection.querySingleInt("SELECT changes()") == 1 else {
            throw DistributionBindingStoreError.conflict
        }
    }
}
