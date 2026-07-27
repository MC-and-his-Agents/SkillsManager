import Darwin
import Foundation
import SQLite3

nonisolated enum SkillDeletionStatus: String, Sendable {
    case ready
    case operationInProgress
    case needsRepair
    case completed
    case cleanupPending
    case rolledBack
}

nonisolated struct SkillContentSummary: Equatable, Sendable {
    let displayName: String
    let contentFingerprint: SkillContentFingerprint
    let statistics: SkillContentSnapshot.Statistics
}

nonisolated struct SkillDistributionTargetSummary: Equatable, Sendable, Identifiable {
    let scopeKey: String
    let canonicalLocator: String

    var id: String { "\(scopeKey)\u{0}\(canonicalLocator)" }
}

nonisolated struct SkillDeletionPreviewToken: Equatable, Sendable {
    let skillID: SkillID
    let databaseRevision: Int64
    let domainPayload: Data
    let expectationPayload: Data
    let ssotIdentity: ManagedItemIdentity
    let contentFingerprint: SkillContentFingerprint
    let statistics: SkillContentSnapshot.Statistics
}

nonisolated struct SkillDeletionPreview: Equatable, Sendable {
    let skillID: SkillID
    let displayName: String
    let content: SkillContentSummary?
    let targets: [SkillDistributionTargetSummary]
    let status: SkillDeletionStatus
    let operation: SkillDeletionResult?
    let token: SkillDeletionPreviewToken?
}

nonisolated struct SkillDeletionResult: Equatable, Sendable {
    let operationID: SSOTOperationID
    let skillID: SkillID
    let backupID: SkillBackupID
    let status: SkillDeletionStatus
}

nonisolated enum SkillRestoreStatus: String, Sendable {
    case ready
    case noOp
    case completed
    case restoredUndistributed
}

nonisolated struct SkillBackupSummary: Equatable, Sendable {
    let content: SkillContentSummary
    let sourceLocator: String?
    let targets: [SkillDistributionTargetSummary]
}

nonisolated struct SkillRestorePreviewToken: Equatable, Sendable {
    let backupUpdatedAtMilliseconds: Int64
    let directoryIdentity: ManagedItemIdentity
    let manifestDigest: Data
    let contentFingerprint: SkillContentFingerprint
    let targetSkillID: SkillID
    let targetRevision: Int64?
    let targetPayload: Data?
}

nonisolated struct SkillRestorePreview: Equatable, Sendable {
    let backupID: SkillBackupID
    let originalSkillID: SkillID
    let targetSkillID: SkillID
    let status: SkillRestoreStatus
    let summary: SkillBackupSummary
    let token: SkillRestorePreviewToken
}

nonisolated struct SkillRestoreResult: Equatable, Sendable {
    let backupID: SkillBackupID
    let restoredSkillID: SkillID
    let status: SkillRestoreStatus
    let warnings: [String]
}

nonisolated enum SkillBackupCatalogAvailability: String, Sendable {
    case available
    case preparing
    case pruning
    case needsRepair
    case corrupt
    case permissionDenied
    case unavailable
}

nonisolated struct SkillBackupCatalogItem: Equatable, Sendable, Identifiable {
    let backupID: SkillBackupID
    let originalSkillID: SkillID
    let availability: SkillBackupCatalogAvailability
    let isPinned: Bool
    let restoredSkillID: SkillID?
    let createdAtMilliseconds: Int64
    let summary: SkillBackupSummary?
    let problem: SkillDeletionError?

    var id: SkillBackupID { backupID }
}

nonisolated enum SkillDeletionError: LocalizedError, Equatable, Sendable {
    case skillNotFound
    case conflict
    case previewExpired
    case operationInProgress
    case needsRepair
    case backupCorrupt
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .skillNotFound: "The managed Skill was not found."
        case .conflict: "The managed Skill changed during deletion."
        case .previewExpired: "The preview expired because the managed state changed."
        case .operationInProgress: "A deletion operation is already in progress."
        case .needsRepair: "The deletion operation requires repair."
        case .backupCorrupt: "The Skill backup is missing or corrupt."
        case .permissionDenied: "Skills Manager does not have permission for this operation."
        case .unavailable: "The deletion service is unavailable."
        }
    }
}

nonisolated enum SkillLifecycleErrorContext {
    case mutation
    case backupRead
}

nonisolated func withStableSkillLifecycleErrors<T>(
    _ context: SkillLifecycleErrorContext,
    operation: () throws -> T
) throws -> T {
    do {
        return try operation()
    } catch is CancellationError {
        throw CancellationError()
    } catch let interruption as SSOTWriterCheckpointInterruption {
        throw interruption
    } catch {
        throw stableSkillLifecycleError(error, context: context)
    }
}

private nonisolated func stableSkillLifecycleError(
    _ error: Error,
    context: SkillLifecycleErrorContext
) -> SkillDeletionError {
    if let stable = error as? SkillDeletionError { return stable }
    if let stable = stableDistributionError(error, context: context) { return stable }
    if let stable = stablePersistenceError(error, context: context) { return stable }
    if let stable = stableStorageError(error) { return stable }
    if error is DecodingError {
        return context == .backupRead ? .backupCorrupt : .needsRepair
    }
    let cocoa = error as NSError
    if cocoa.domain == NSPOSIXErrorDomain {
        return stablePOSIXError(Int32(cocoa.code))
    }
    if cocoa.domain == NSCocoaErrorDomain,
       cocoa.code == NSFileReadNoPermissionError
        || cocoa.code == NSFileWriteNoPermissionError {
        return .permissionDenied
    }
    return .unavailable
}

private nonisolated func stableDistributionError(
    _ error: Error,
    context: SkillLifecycleErrorContext
) -> SkillDeletionError? {
    if let executor = error as? DistributionSymlinkExecutorError {
        return switch executor {
        case .needsRepair: .needsRepair
        case .operationInProgress: .operationInProgress
        case .conflict: .conflict
        case .blocked(let conflicts):
            conflicts.contains(where: {
                $0.reason == .targetUnavailable
                    || $0.reason == .dedicatedTargetUnavailable
            }) ? .unavailable : .conflict
        }
    }
    if let fileSystem = error as? DistributionSymlinkFileSystemError {
        return switch fileSystem {
        case .unavailable: .unavailable
        case .posix(_, let code): stablePOSIXError(code)
        default: .conflict
        }
    }
    if let backup = error as? SkillBackupFileSystemError {
        return switch backup {
        case .posix(_, let code): stablePOSIXError(code)
        case .contentChanged, .manifestChanged, .preparedContentMissing:
            context == .backupRead ? .backupCorrupt : .conflict
        case .invalidLocator, .itemChanged:
            context == .backupRead ? .backupCorrupt : .conflict
        case .destinationExists: .conflict
        }
    }
    return nil
}

private nonisolated func stablePersistenceError(
    _ error: Error,
    context: SkillLifecycleErrorContext
) -> SkillDeletionError? {
    if let store = error as? SkillBackupStoreError {
        return switch store {
        case .conflict, .invalidRecord: .conflict
        case .corruptRecord: .backupCorrupt
        }
    }
    if error is SkillBackupManifestError {
        return context == .backupRead ? .backupCorrupt : .conflict
    }
    if error is SkillBackupRecordError {
        return context == .backupRead ? .backupCorrupt : .conflict
    }
    if let store = error as? SkillDeletionOperationStoreError {
        return switch store {
        case .conflict, .operationNotFound: .conflict
        case .invalidRecord, .corruptRecord: .needsRepair
        }
    }
    if error is SSOTWritePayloadError {
        return context == .backupRead ? .backupCorrupt : .needsRepair
    }
    if let journal = error as? SSOTJournalStoreError {
        return switch journal {
        case .stateConflict, .databaseConflict, .operationNotFound: .conflict
        case .invalidRecord, .payloadMismatch, .corruptRecord: .needsRepair
        }
    }
    if let writer = error as? JournaledSSOTWriterError {
        return switch writer {
        case .operationNeedsRepair, .recoveryDidNotConverge: .needsRepair
        case .invalidInput, .operationRolledBack: .conflict
        }
    }
    return nil
}

private nonisolated func stableStorageError(_ error: Error) -> SkillDeletionError? {
    if let fileSystem = error as? SSOTOperationFileSystemError {
        return switch fileSystem {
        case .posix(_, let code): stablePOSIXError(code)
        case .stagingCleanupFailed: .needsRepair
        case .invalidOperationItemRole, .stagingAlreadyExists,
             .stagedContentMismatch, .destinationAlreadyExists, .itemChanged:
            .conflict
        }
    }
    if let durability = error as? SSOTDurabilityError {
        return switch durability {
        case .posix(_, let code): stablePOSIXError(code)
        }
    }
    if error is ManagedPromotionIndeterminate {
        return .needsRepair
    }
    if let ownership = error as? SSOTWriterOwnershipError {
        return switch ownership {
        case .busy: .operationInProgress
        case .posix(_, let code): stablePOSIXError(code)
        case .invalidLockFile: .unavailable
        }
    }
    if let managed = error as? ManagedPathError {
        return switch managed {
        case .posix(_, let code): stablePOSIXError(code)
        case .cleanupFailed, .removalFailed: .needsRepair
        default: .conflict
        }
    }
    if let sqlite = error as? SQLiteStoreError {
        return stableSQLiteError(sqlite)
    }
    return nil
}

private nonisolated func stablePOSIXError(_ code: Int32) -> SkillDeletionError {
    code == EACCES || code == EPERM ? .permissionDenied : .unavailable
}

private nonisolated func stableSQLiteError(_ error: SQLiteStoreError) -> SkillDeletionError {
    guard case .sqlite(_, let code, _) = error else { return .unavailable }
    return switch code & 0xFF {
    case SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY:
        .permissionDenied
    case SQLITE_BUSY, SQLITE_LOCKED:
        .operationInProgress
    default:
        .unavailable
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
