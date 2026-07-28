import Foundation

nonisolated struct CopyForkTargetReservation: Hashable, Sendable {
    let scopeKey: String
    let slugKey: String
}

nonisolated struct CopyForkAdmission {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func reserve(_ record: CopyForkOperationRecord) throws {
        try connection.withImmediateTransaction {
            try requireNoUnindexedHostOperation()
            try requireAvailable(
                skillIDs: [record.parentSkillID, record.childSkillID],
                target: CopyForkTargetReservation(
                    scopeKey: record.parentBinding.scope.targetScopeKey,
                    slugKey: record.parentBinding.distributionSlug.collisionKey
                ),
                bypassCopyFork: nil,
                bypassHostOperation: nil
            )
            try CopyForkOperationStore(connection: connection).insertReservation(record)
        }
    }

    private func requireNoUnindexedHostOperation() throws {
        let activeDeletion = try connection.querySingleInt(
            """
            SELECT count(*) FROM skill_deletion_operations
            WHERE outcome IN ('pending', 'needsRepair')
               OR cleanup_state IN ('pending', 'needsRepair')
            """
        )
        let unfinishedRestore = try connection.querySingleInt(
            """
            SELECT count(*) FROM skill_backups
            WHERE restored_skill_id IS NOT NULL
              AND restore_result_json IS NULL
            """
        )
        // ponytail: these legacy records have no indexed target set; keep the
        // conservative global gate until a future schema persists one.
        guard activeDeletion == 0, unfinishedRestore == 0 else {
            throw CopyForkError.operationInProgress
        }
    }

    func requireAvailable(
        skillIDs: Set<SkillID>,
        target: CopyForkTargetReservation? = nil,
        bypassCopyFork: SSOTOperationID? = nil,
        bypassHostOperation: SSOTOperationID? = nil
    ) throws {
        guard !skillIDs.isEmpty else { return }
        if try activeCopyForkConflicts(
            skillIDs: skillIDs,
            target: target,
            bypass: bypassCopyFork
        ) {
            throw CopyForkError.operationInProgress
        }
        for table in [
            ("skill_operations", "skill_id", "phase <> 'completed' OR outcome = 'needsRepair'"
                + " OR cleanup_state IN ('pending', 'needsRepair')"),
            ("skill_deletion_operations", "skill_id",
                "outcome IN ('pending', 'needsRepair')"
                + " OR cleanup_state IN ('pending', 'needsRepair')"),
        ] where try count(
            table: table.0,
            skillColumn: table.1,
            predicate: table.2,
            skillIDs: skillIDs,
            bypass: bypassHostOperation
        ) > 0 {
            throw CopyForkError.operationInProgress
        }
        if try activeBackupConflicts(skillIDs) {
            throw CopyForkError.operationInProgress
        }
        let distributionStore = try DistributionOperationStore(connection: connection)
        for operation in try distributionStore.recoverableOperations()
            + distributionStore.repairRequiredOperations() {
            if skillIDs.contains(operation.skillID)
                || target.map({ operationTouches(operation, target: $0) }) == true {
                throw CopyForkError.operationInProgress
            }
        }
    }

    private func activeCopyForkConflicts(
        skillIDs: Set<SkillID>,
        target: CopyForkTargetReservation?,
        bypass: SSOTOperationID?
    ) throws -> Bool {
        try CopyForkOperationStore(connection: connection).active().contains { record in
            guard record.operationID != bypass else { return false }
            return skillIDs.contains(record.parentSkillID)
                || skillIDs.contains(record.childSkillID)
                || target == CopyForkTargetReservation(
                    scopeKey: record.parentBinding.scope.targetScopeKey,
                    slugKey: record.parentBinding.distributionSlug.collisionKey
                )
        }
    }

    private func count(
        table: String,
        skillColumn: String,
        predicate: String,
        skillIDs: Set<SkillID>,
        bypass: SSOTOperationID?
    ) throws -> Int64 {
        let placeholders = skillIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try connection.prepare(
            "SELECT count(*) FROM \(table) WHERE \(skillColumn) IN (\(placeholders))"
                + " AND (\(predicate))"
                + (bypass == nil ? "" : " AND operation_id <> ?")
        )
        var index: Int32 = 1
        for skillID in skillIDs.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
            try statement.bind(skillID.bytes, at: index)
            index += 1
        }
        if let bypass { try statement.bind(bypass.bytes, at: index) }
        guard try statement.step() else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return statement.int64(at: 0)
    }

    private func activeBackupConflicts(_ skillIDs: Set<SkillID>) throws -> Bool {
        let placeholders = skillIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try connection.prepare(
            """
            SELECT count(*) FROM skill_backups
            WHERE state IN ('preparing', 'needsRepair')
              AND (original_skill_id IN (\(placeholders))
                OR restored_skill_id IN (\(placeholders)))
            """
        )
        var index: Int32 = 1
        let ordered = skillIDs.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        for skillID in ordered {
            try statement.bind(skillID.bytes, at: index)
            index += 1
        }
        for skillID in ordered {
            try statement.bind(skillID.bytes, at: index)
            index += 1
        }
        guard try statement.step() else {
            throw CopyForkOperationStoreError.corruptRecord
        }
        return statement.int64(at: 0) > 0
    }

    private func operationTouches(
        _ operation: DistributionOperationRecord,
        target: CopyForkTargetReservation
    ) -> Bool {
        if bindings(in: operation.oldBindings).contains(where: {
            bindingTouches($0, target: target)
        }) || bindings(in: operation.newBindings).contains(where: {
            bindingTouches($0, target: target)
        }) {
            return true
        }
        guard let object = try? JSONSerialization.jsonObject(with: operation.planPayload)
            as? [String: Any],
              let actions = object["filesystem_actions"] as? [[String: Any]] else {
            return true
        }
        if actions.contains(where: {
            $0["target_scope_key"] as? String == target.scopeKey
                && collisionKey($0) == target.slugKey
        }) {
            return true
        }
        guard let bindings = object["binding_replacement"] as? [[String: Any]] else {
            return true
        }
        return bindings.contains {
            $0["target_scope_key"] as? String == target.scopeKey
                && collisionKey($0) == target.slugKey
        }
    }

    private func bindings(in data: Data) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private func bindingTouches(
        _ binding: [String: Any],
        target: CopyForkTargetReservation
    ) -> Bool {
        let scopeKey: String?
        switch binding["scope"] as? String {
        case "global":
            scopeKey = "global"
        case "agent":
            scopeKey = (binding["adapter"] as? String).map { "agent:\($0)" }
        default:
            scopeKey = binding["target_scope_key"] as? String
        }
        let legacySlug = (binding["slug"] as? String).flatMap {
            try? DefaultDistributionSlug(validating: $0)
        }
        let slugKey = collisionKey(binding) ?? legacySlug?.collisionKey
        return scopeKey == target.scopeKey && slugKey == target.slugKey
    }

    private func collisionKey(_ object: [String: Any]) -> String? {
        if let key = object["slug_key"] as? String { return key }
        guard let slug = object["distribution_slug"] as? String,
              let validated = try? DefaultDistributionSlug(validating: slug) else {
            return nil
        }
        return validated.collisionKey
    }
}
