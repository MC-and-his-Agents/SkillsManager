import Foundation

nonisolated enum SkillDeletionStatus: String, Sendable {
    case ready
    case operationInProgress
    case needsRepair
    case completed
    case cleanupPending
}

nonisolated struct SkillDeletionPreview: Sendable {
    let skillID: SkillID
    let displayName: String
    let distributedTargetCount: Int
    let status: SkillDeletionStatus
}

nonisolated struct SkillDeletionResult: Sendable {
    let operationID: SSOTOperationID
    let backupID: SkillBackupID
    let status: SkillDeletionStatus
}

nonisolated enum SkillRestoreStatus: String, Sendable {
    case ready
    case noOp
    case completed
    case restoredUndistributed
}

nonisolated struct SkillRestorePreview: Sendable {
    let backupID: SkillBackupID
    let originalSkillID: SkillID
    let targetSkillID: SkillID
    let status: SkillRestoreStatus
}

nonisolated struct SkillRestoreResult: Sendable {
    let backupID: SkillBackupID
    let restoredSkillID: SkillID
    let status: SkillRestoreStatus
    let warnings: [String]
}

nonisolated enum SkillDeletionError: LocalizedError, Equatable {
    case skillNotFound
    case conflict
    case operationInProgress
    case needsRepair
    case backupCorrupt
    case unavailable

    var errorDescription: String? {
        switch self {
        case .skillNotFound: "The managed Skill was not found."
        case .conflict: "The managed Skill changed during deletion."
        case .operationInProgress: "A deletion operation is already in progress."
        case .needsRepair: "The deletion operation requires repair."
        case .backupCorrupt: "The Skill backup is missing or corrupt."
        case .unavailable: "The deletion service is unavailable."
        }
    }
}

nonisolated struct SkillDeletionExpectation: Sendable {
    let databaseRevision: Int64
    let selection: DistributionSelectionReadback
    let ownership: [DistributionLinkOwnership]

    func canonicalData() throws -> Data {
        try SkillBackupCanonicalJSON.encode(Wire(self))
    }

    static func decode(_ data: Data, skillID: SkillID) throws -> Self {
        try SkillBackupCanonicalJSON.validate(data)
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return try wire.value(skillID: skillID)
    }

    private struct Wire: Codable {
        struct Binding: Codable {
            let scope: String
            let adapter: String?
            let slug: String
            let syncMode: String
            let createdAtMilliseconds: Int64
            let updatedAtMilliseconds: Int64
        }

        struct Ownership: Codable {
            let targetScopeKey: String
            let appliedOperationID: String
            let rootIdentity: String
            let entryIdentity: String
            let absoluteLinkTarget: String
            let verifiedAtMilliseconds: Int64
        }

        let databaseRevision: Int64
        let explicitlyConfigured: Bool
        let bindings: [Binding]
        let ownership: [Ownership]

        init(_ expectation: SkillDeletionExpectation) throws {
            databaseRevision = expectation.databaseRevision
            explicitlyConfigured = expectation.selection.isExplicitlyConfigured
            bindings = expectation.selection.bindings
                .sorted { $0.scope.targetScopeKey < $1.scope.targetScopeKey }
                .map {
                    Binding(
                        scope: $0.scope.kind,
                        adapter: $0.scope.adapter?.storageKey,
                        slug: $0.distributionSlug.value,
                        syncMode: $0.syncMode.rawValue,
                        createdAtMilliseconds: $0.createdAtMilliseconds,
                        updatedAtMilliseconds: $0.updatedAtMilliseconds
                    )
                }
            ownership = try expectation.ownership
                .sorted { $0.targetScopeKey < $1.targetScopeKey }
                .map {
                    Ownership(
                        targetScopeKey: $0.targetScopeKey,
                        appliedOperationID: $0.appliedOperationID.uuid.uuidString.lowercased(),
                        rootIdentity: Self.hex(
                            try ManagedItemIdentityCodec.encode($0.rootIdentity)
                        ),
                        entryIdentity: Self.hex(
                            try ManagedItemIdentityCodec.encode($0.entryIdentity)
                        ),
                        absoluteLinkTarget: $0.absoluteLinkTarget,
                        verifiedAtMilliseconds: $0.verifiedAtMilliseconds
                    )
                }
        }

        func value(skillID: SkillID) throws -> SkillDeletionExpectation {
            guard databaseRevision >= 0,
                  Set(bindings.map { "\($0.scope):\($0.adapter ?? "")" }).count
                    == bindings.count,
                  Set(ownership.map(\.targetScopeKey)).count == ownership.count else {
                throw SkillDeletionError.backupCorrupt
            }
            let decodedBindings = try bindings.map { value in
                let scope: DistributionBindingScope
                switch (value.scope, value.adapter) {
                case ("global", nil):
                    scope = .global
                case ("agent", let adapter?):
                    guard let platform = SkillPlatform.allCases.first(where: {
                        $0.storageKey == adapter
                    }) else { throw SkillDeletionError.backupCorrupt }
                    scope = .agent(platform)
                default:
                    throw SkillDeletionError.backupCorrupt
                }
                guard let syncMode = DistributionSyncMode(rawValue: value.syncMode) else {
                    throw SkillDeletionError.backupCorrupt
                }
                return try DistributionBinding(
                    skillID: skillID,
                    scope: scope,
                    distributionSlug: DefaultDistributionSlug(validating: value.slug),
                    syncMode: syncMode,
                    createdAtMilliseconds: value.createdAtMilliseconds,
                    updatedAtMilliseconds: value.updatedAtMilliseconds
                )
            }
            let decodedOwnership = try ownership.map { value in
                guard let operationUUID = UUID(uuidString: value.appliedOperationID) else {
                    throw SkillDeletionError.backupCorrupt
                }
                return try DistributionLinkOwnership(
                    skillID: skillID,
                    targetScopeKey: value.targetScopeKey,
                    appliedOperationID: SSOTOperationID(operationUUID),
                    rootIdentity: ManagedItemIdentityCodec.decode(try Self.data(value.rootIdentity)),
                    entryIdentity: ManagedItemIdentityCodec.decode(try Self.data(value.entryIdentity)),
                    absoluteLinkTarget: value.absoluteLinkTarget,
                    verifiedAtMilliseconds: value.verifiedAtMilliseconds
                )
            }
            return SkillDeletionExpectation(
                databaseRevision: databaseRevision,
                selection: DistributionSelectionReadback(
                    bindings: decodedBindings,
                    isExplicitlyConfigured: explicitlyConfigured
                ),
                ownership: decodedOwnership
            )
        }

        private static func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        private static func data(_ value: String) throws -> Data {
            guard value.count.isMultiple(of: 2), value == value.lowercased() else {
                throw SkillDeletionError.backupCorrupt
            }
            var result = Data()
            var index = value.startIndex
            while index < value.endIndex {
                let next = value.index(index, offsetBy: 2)
                guard let byte = UInt8(value[index..<next], radix: 16) else {
                    throw SkillDeletionError.backupCorrupt
                }
                result.append(byte)
                index = next
            }
            return result
        }
    }
}
