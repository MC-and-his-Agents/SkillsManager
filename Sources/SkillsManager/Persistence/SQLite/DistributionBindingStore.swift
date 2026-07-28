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
        try connection.withImmediateTransaction {
            try replaceInCurrentTransaction(
                skillID: skillID,
                expectedOld: expectedOld,
                desired: desired,
                nowMilliseconds: nowMilliseconds
            )
        }
    }

    func replaceInCurrentTransaction(
        skillID: SkillID,
        expectedOld: [DistributionBinding],
        desired: [DistributionBindingIntent],
        nowMilliseconds: Int64
    ) throws -> [DistributionBinding] {
        let actual = try loadBindings(skillID: skillID)
        guard canonical(expectedOld) == actual else {
            throw DistributionBindingStoreError.conflict
        }
        guard nowMilliseconds >= 0 else {
            throw DistributionBindingStoreError.invalidInput
        }
        let desired = try canonicalDesired(desired, skillID: skillID)
        guard desired.allSatisfy({ $0.syncMode == .symlink }) else {
            throw DistributionBindingStoreError.invalidInput
        }
        guard actual.map(\.intent) != desired else { return actual }

        let actualByScope = Dictionary(
            uniqueKeysWithValues: actual.map { ($0.scope.targetScopeKey, $0) }
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

        return try writeReplacement(
            skillID: skillID,
            actual: actual,
            replacement: replacement
        )
    }

    func replaceFinalizedInCurrentTransaction(
        skillID: SkillID,
        expectedOld: [DistributionBinding],
        desired: [DistributionBinding]
    ) throws -> [DistributionBinding] {
        let actual = try loadBindings(skillID: skillID)
        guard canonical(expectedOld) == actual else {
            throw DistributionBindingStoreError.conflict
        }
        let replacement = canonical(desired)
        guard replacement.allSatisfy({ $0.skillID == skillID }),
              Set(replacement.map(\.scope.targetScopeKey)).count == replacement.count,
              Set(replacement.map(\.syncMode)).count <= 1 else {
            throw DistributionBindingStoreError.invalidInput
        }
        let globalCount = replacement.count { $0.scope == .global }
        guard (globalCount == 0 || (globalCount == 1 && replacement.count == 1)),
              Set(replacement.map(\.distributionSlug)).count <= 1 else {
            throw DistributionBindingStoreError.invalidInput
        }
        guard replacement != actual else { return actual }
        return try writeReplacement(
            skillID: skillID,
            actual: actual,
            replacement: replacement
        )
    }

    private func loadBindings(skillID: SkillID) throws -> [DistributionBinding] {
        let statement = try connection.prepare(
            """
            SELECT scope_kind, adapter_code, target_scope_key,
              distribution_slug, slug_key, sync_mode,
              copy_content_algorithm_version, copy_content_fingerprint,
              copy_tree_algorithm_version, copy_tree_digest,
              copy_root_identity, copy_entry_identity,
              copy_provenance_kind, copy_applied_operation_id,
              copy_fork_operation_id, copy_verified_at_ms,
              created_at_ms, updated_at_ms
            FROM distribution_bindings WHERE skill_id = ?
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        var bindings: [DistributionBinding] = []
        while try statement.step() {
            bindings.append(try decode(statement, skillID: skillID))
        }
        let result = canonical(bindings)
        let globalCount = result.count { $0.scope == .global }
        guard Set(result.map(\.scope.targetScopeKey)).count == result.count,
              Set(result.map(\.syncMode)).count <= 1,
              globalCount == 0 || (globalCount == 1 && result.count == 1) else {
            throw DistributionBindingStoreError.corruptRecord
        }
        return result
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
            let binding = try DistributionBinding(
                skillID: skillID,
                scope: scope,
                distributionSlug: slug,
                syncMode: syncMode,
                copyBaseline: try decodeCopyBaseline(statement, syncMode: syncMode),
                createdAtMilliseconds: statement.int64(at: 16),
                updatedAtMilliseconds: statement.int64(at: 17)
            )
            try CopyForkOperationStore(connection: connection)
                .requireCompletedBindingEvidence(binding)
            return binding
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
        guard (globalCount == 0 || (globalCount == 1 && desired.count == 1)),
              Set(desired.map(\.syncMode)).count <= 1 else {
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
            SET distribution_slug = ?, slug_key = ?, sync_mode = ?,
                copy_content_algorithm_version = ?, copy_content_fingerprint = ?,
                copy_tree_algorithm_version = ?, copy_tree_digest = ?,
                copy_root_identity = ?, copy_entry_identity = ?,
                copy_provenance_kind = ?, copy_applied_operation_id = ?,
                copy_fork_operation_id = ?, copy_verified_at_ms = ?,
                updated_at_ms = ?
            WHERE skill_id = ? AND target_scope_key = ?
            """
        )
        try statement.bind(binding.distributionSlug.value, at: 1)
        try statement.bind(binding.distributionSlug.collisionKey, at: 2)
        try statement.bind(binding.syncMode.rawValue, at: 3)
        try bindCopyBaseline(binding.copyBaseline, to: statement, startingAt: 4)
        try statement.bind(binding.updatedAtMilliseconds, at: 14)
        try statement.bind(binding.skillID.bytes, at: 15)
        try statement.bind(binding.scope.targetScopeKey, at: 16)
        try finishExactlyOne(statement)
    }

    private func insert(_ binding: DistributionBinding) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO distribution_bindings(
              skill_id, scope_kind, adapter_code, target_scope_key,
              distribution_slug, slug_key, sync_mode,
              copy_content_algorithm_version, copy_content_fingerprint,
              copy_tree_algorithm_version, copy_tree_digest,
              copy_root_identity, copy_entry_identity,
              copy_provenance_kind, copy_applied_operation_id,
              copy_fork_operation_id, copy_verified_at_ms,
              created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        try bindCopyBaseline(binding.copyBaseline, to: statement, startingAt: 8)
        try statement.bind(binding.createdAtMilliseconds, at: 18)
        try statement.bind(binding.updatedAtMilliseconds, at: 19)
        try finishExactlyOne(statement)
    }

    private func writeReplacement(
        skillID: SkillID,
        actual: [DistributionBinding],
        replacement: [DistributionBinding]
    ) throws -> [DistributionBinding] {
        let actualByScope = Dictionary(
            uniqueKeysWithValues: actual.map { ($0.scope.targetScopeKey, $0) }
        )
        let desiredKeys = Set(replacement.map(\.scope.targetScopeKey))
        for binding in actual where !desiredKeys.contains(binding.scope.targetScopeKey) {
            try delete(binding)
        }
        for binding in replacement {
            if let old = actualByScope[binding.scope.targetScopeKey] {
                if old != binding { try update(old, to: binding) }
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

    private func decodeCopyBaseline(
        _ statement: SQLiteStatement,
        syncMode: DistributionSyncMode
    ) throws -> DistributionCopyBaseline? {
        if syncMode == .symlink {
            guard (6...15).allSatisfy({ statement.isNull(at: Int32($0)) }) else {
                throw DistributionBindingStoreError.corruptRecord
            }
            return nil
        }
        guard !statement.isNull(at: 6),
              let contentDigest = statement.blob(at: 7),
              !statement.isNull(at: 8),
              let treeDigest = statement.blob(at: 9),
              let rootIdentity = statement.blob(at: 10),
              let entryIdentity = statement.blob(at: 11),
              let provenanceKind = statement.text(at: 12),
              !statement.isNull(at: 15) else {
            throw DistributionBindingStoreError.corruptRecord
        }
        let provenance: DistributionCopyBaseline.Provenance
        switch provenanceKind {
        case "distribution":
            guard let operationID = statement.blob(at: 13),
                  statement.isNull(at: 14) else {
                throw DistributionBindingStoreError.corruptRecord
            }
            provenance = .distribution(try SSOTOperationID(bytes: operationID))
        case "copyFork":
            guard statement.isNull(at: 13),
                  let operationID = statement.blob(at: 14) else {
                throw DistributionBindingStoreError.corruptRecord
            }
            provenance = .copyFork(try SSOTOperationID(bytes: operationID))
        default:
            throw DistributionBindingStoreError.corruptRecord
        }
        return try DistributionCopyBaseline(
            contentFingerprint: SkillContentFingerprint(
                algorithmVersion: Int(statement.int64(at: 6)),
                digest: contentDigest
            ),
            physicalTreeDigest: CopyPhysicalTreeDigest(
                algorithmVersion: Int(statement.int64(at: 8)),
                digest: treeDigest
            ),
            rootIdentity: ManagedItemIdentityCodec.decode(rootIdentity),
            entryIdentity: ManagedItemIdentityCodec.decode(entryIdentity),
            provenance: provenance,
            verifiedAtMilliseconds: statement.int64(at: 15)
        )
    }

    private func bindCopyBaseline(
        _ baseline: DistributionCopyBaseline?,
        to statement: SQLiteStatement,
        startingAt start: Int32
    ) throws {
        guard let baseline else {
            for index in start..<(start + 10) { try statement.bindNull(at: index) }
            return
        }
        try statement.bind(Int64(baseline.contentFingerprint.algorithmVersion), at: start)
        try statement.bind(baseline.contentFingerprint.digest, at: start + 1)
        try statement.bind(Int64(baseline.physicalTreeDigest.algorithmVersion), at: start + 2)
        try statement.bind(baseline.physicalTreeDigest.digest, at: start + 3)
        try statement.bind(try ManagedItemIdentityCodec.encode(baseline.rootIdentity), at: start + 4)
        try statement.bind(try ManagedItemIdentityCodec.encode(baseline.entryIdentity), at: start + 5)
        switch baseline.provenance {
        case .distribution(let operationID):
            try statement.bind("distribution", at: start + 6)
            try statement.bind(operationID.bytes, at: start + 7)
            try statement.bindNull(at: start + 8)
        case .copyFork(let operationID):
            try statement.bind("copyFork", at: start + 6)
            try statement.bindNull(at: start + 7)
            try statement.bind(operationID.bytes, at: start + 8)
        }
        try statement.bind(baseline.verifiedAtMilliseconds, at: start + 9)
    }

    private func finishExactlyOne(_ statement: SQLiteStatement) throws {
        guard try !statement.step(),
              try connection.querySingleInt("SELECT changes()") == 1 else {
            throw DistributionBindingStoreError.conflict
        }
    }
}
