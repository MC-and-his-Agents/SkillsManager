import Foundation

nonisolated struct DistributionLinkOwnership: Equatable, Hashable, Sendable {
    let skillID: SkillID
    let targetScopeKey: String
    let appliedOperationID: SSOTOperationID
    let rootIdentity: ManagedItemIdentity
    let entryIdentity: ManagedItemIdentity
    let absoluteLinkTarget: String
    let verifiedAtMilliseconds: Int64

    init(
        skillID: SkillID,
        targetScopeKey: String,
        appliedOperationID: SSOTOperationID,
        rootIdentity: ManagedItemIdentity,
        entryIdentity: ManagedItemIdentity,
        absoluteLinkTarget: String,
        verifiedAtMilliseconds: Int64
    ) throws {
        guard !targetScopeKey.isEmpty, targetScopeKey.utf8.count <= 32,
              absoluteLinkTarget.hasPrefix("/"),
              absoluteLinkTarget.utf8.count <= 8_192,
              verifiedAtMilliseconds >= 0 else {
            throw DistributionLinkOwnershipStoreError.invalidInput
        }
        self.skillID = skillID
        self.targetScopeKey = targetScopeKey
        self.appliedOperationID = appliedOperationID
        self.rootIdentity = rootIdentity
        self.entryIdentity = entryIdentity
        self.absoluteLinkTarget = absoluteLinkTarget
        self.verifiedAtMilliseconds = verifiedAtMilliseconds
    }
}

nonisolated enum DistributionLinkOwnershipStoreError: Error, Equatable, LocalizedError {
    case invalidInput
    case conflict
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .invalidInput: "The distribution link ownership record is invalid."
        case .conflict: "The distribution link ownership changed concurrently."
        case .corruptRecord: "The distribution link ownership record is corrupt."
        }
    }
}

nonisolated struct DistributionLinkOwnershipStore {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func load(skillID: SkillID) throws -> [DistributionLinkOwnership] {
        let statement = try connection.prepare(
            """
            SELECT target_scope_key, applied_operation_id, root_identity, entry_identity,
                   absolute_link_target, verified_at_ms
            FROM distribution_link_ownership
            WHERE skill_id = ? ORDER BY target_scope_key
            """
        )
        try statement.bind(skillID.bytes, at: 1)
        var result: [DistributionLinkOwnership] = []
        while try statement.step() {
            do {
                result.append(try DistributionLinkOwnership(
                    skillID: skillID,
                    targetScopeKey: try distributionRequiredText(statement, 0),
                    appliedOperationID: try SSOTOperationID(
                        bytes: try ownershipRequiredBlob(statement, 1)
                    ),
                    rootIdentity: try ManagedItemIdentityCodec.decode(
                        ownershipRequiredBlob(statement, 2)
                    ),
                    entryIdentity: try ManagedItemIdentityCodec.decode(
                        ownershipRequiredBlob(statement, 3)
                    ),
                    absoluteLinkTarget: try distributionRequiredText(statement, 4),
                    verifiedAtMilliseconds: statement.int64(at: 5)
                ))
            } catch let error as DistributionLinkOwnershipStoreError {
                throw error
            } catch {
                throw DistributionLinkOwnershipStoreError.corruptRecord
            }
        }
        return result
    }

    func replace(
        skillID: SkillID,
        expectedOld: [DistributionLinkOwnership],
        desired: [DistributionLinkOwnership],
        appliedOperationID: SSOTOperationID,
        nowMilliseconds: Int64
    ) throws -> [DistributionLinkOwnership] {
        try connection.withImmediateTransaction {
            try replaceInCurrentTransaction(
                skillID: skillID,
                expectedOld: expectedOld,
                desired: desired,
                appliedOperationID: appliedOperationID,
                nowMilliseconds: nowMilliseconds
            )
        }
    }

    func replaceInCurrentTransaction(
        skillID: SkillID,
        expectedOld: [DistributionLinkOwnership],
        desired: [DistributionLinkOwnership],
        appliedOperationID: SSOTOperationID,
        nowMilliseconds: Int64
    ) throws -> [DistributionLinkOwnership] {
        guard nowMilliseconds >= 0,
              expectedOld.allSatisfy({ $0.skillID == skillID }),
              desired.allSatisfy({
                  $0.skillID == skillID && $0.appliedOperationID == appliedOperationID
              }) else {
            throw DistributionLinkOwnershipStoreError.invalidInput
        }
        let old = try load(skillID: skillID)
        guard canonical(old) == canonical(expectedOld) else {
            throw DistributionLinkOwnershipStoreError.conflict
        }
        let replacement = canonical(desired)
        guard Set(replacement.map(\.targetScopeKey)).count == replacement.count else {
            throw DistributionLinkOwnershipStoreError.invalidInput
        }
        guard replacement.allSatisfy({ $0.verifiedAtMilliseconds >= 0 }) else {
            throw DistributionLinkOwnershipStoreError.invalidInput
        }
        if old == replacement { return old }

        let delete = try connection.prepare(
            "DELETE FROM distribution_link_ownership WHERE skill_id = ?"
        )
        try delete.bind(skillID.bytes, at: 1)
        guard try !delete.step() else {
            throw DistributionLinkOwnershipStoreError.corruptRecord
        }
        for ownership in replacement {
            let statement = try connection.prepare(
                """
                INSERT INTO distribution_link_ownership(
                  skill_id, target_scope_key, applied_operation_id,
                  root_identity, entry_identity, absolute_link_target, verified_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            try statement.bind(ownership.skillID.bytes, at: 1)
            try statement.bind(ownership.targetScopeKey, at: 2)
            try statement.bind(ownership.appliedOperationID.bytes, at: 3)
            try statement.bind(try ManagedItemIdentityCodec.encode(ownership.rootIdentity), at: 4)
            try statement.bind(try ManagedItemIdentityCodec.encode(ownership.entryIdentity), at: 5)
            try statement.bind(ownership.absoluteLinkTarget, at: 6)
            try statement.bind(ownership.verifiedAtMilliseconds, at: 7)
            guard try !statement.step() else {
                throw DistributionLinkOwnershipStoreError.corruptRecord
            }
        }
        let readback = try load(skillID: skillID)
        guard readback == replacement else {
            throw DistributionLinkOwnershipStoreError.conflict
        }
        return readback
    }

    private func canonical(
        _ rows: [DistributionLinkOwnership]
    ) -> [DistributionLinkOwnership] {
        rows.sorted {
            $0.targetScopeKey.utf8.lexicographicallyPrecedes($1.targetScopeKey.utf8)
        }
    }
}

private nonisolated func distributionRequiredText(
    _ statement: SQLiteStatement,
    _ column: Int32
) throws -> String {
    guard let value = statement.text(at: column) else {
        throw DistributionLinkOwnershipStoreError.corruptRecord
    }
    return value
}

private nonisolated func ownershipRequiredBlob(
    _ statement: SQLiteStatement,
    _ column: Int32
) throws -> Data {
    guard let value = statement.blob(at: column) else {
        throw DistributionLinkOwnershipStoreError.corruptRecord
    }
    return value
}
