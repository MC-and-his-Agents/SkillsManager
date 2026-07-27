import Foundation

nonisolated struct SkillBackupID: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    init(bytes: Data) throws {
        uuid = try SkillID(bytes: bytes).uuid
    }

    var bytes: Data { SkillID(uuid).bytes }
}

nonisolated enum SkillBackupState: String, CaseIterable, Codable, Sendable {
    case preparing
    case available
    case pruning
    case needsRepair
}

nonisolated enum SkillBackupRecordError: Error, Equatable {
    case invalidRecord
    case invalidTransition
}

nonisolated enum SkillBackupCanonicalJSON {
    static let maximumByteCount = 131_072

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try validate(data)
        return data
    }

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumByteCount else {
            throw SkillBackupRecordError.invalidRecord
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SkillBackupRecordError.invalidRecord
        }
        guard object is [String: Any],
              JSONSerialization.isValidJSONObject(object),
              try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) == data else {
            throw SkillBackupRecordError.invalidRecord
        }
    }
}

nonisolated struct SkillBackupRecord: Equatable, Sendable {
    let backupID: SkillBackupID
    let originalSkillID: SkillID
    let state: SkillBackupState
    let locator: String
    let directoryIdentity: ManagedItemIdentity
    let manifestDigest: Data
    let contentFingerprint: SkillContentFingerprint
    let isPinned: Bool
    let restoredSkillID: SkillID?
    let restoreResultJSON: Data?
    let pruneQuarantineLocator: String?
    let pruneQuarantineIdentity: ManagedItemIdentity?
    let lastError: String?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(
        backupID: SkillBackupID,
        originalSkillID: SkillID,
        state: SkillBackupState,
        locator: String,
        directoryIdentity: ManagedItemIdentity,
        manifestDigest: Data,
        contentFingerprint: SkillContentFingerprint,
        isPinned: Bool = false,
        restoredSkillID: SkillID? = nil,
        restoreResultJSON: Data? = nil,
        pruneQuarantineLocator: String? = nil,
        pruneQuarantineIdentity: ManagedItemIdentity? = nil,
        lastError: String? = nil,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) throws {
        self.backupID = backupID
        self.originalSkillID = originalSkillID
        self.state = state
        self.locator = locator
        self.directoryIdentity = directoryIdentity
        self.manifestDigest = manifestDigest
        self.contentFingerprint = contentFingerprint
        self.isPinned = isPinned
        self.restoredSkillID = restoredSkillID
        self.restoreResultJSON = restoreResultJSON
        self.pruneQuarantineLocator = pruneQuarantineLocator
        self.pruneQuarantineIdentity = pruneQuarantineIdentity
        self.lastError = lastError
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        try validate()
    }

    func validateTransition(from old: Self) throws {
        guard backupID == old.backupID,
              originalSkillID == old.originalSkillID,
              locator == old.locator,
              directoryIdentity == old.directoryIdentity,
              manifestDigest == old.manifestDigest,
              contentFingerprint == old.contentFingerprint,
              createdAtMilliseconds == old.createdAtMilliseconds,
              updatedAtMilliseconds >= old.updatedAtMilliseconds,
              old.restoredSkillID == nil || restoredSkillID == old.restoredSkillID,
              Self.transitionAllowed(from: old.state, to: state) else {
            throw SkillBackupRecordError.invalidTransition
        }
        try validate()
    }

    private func validate() throws {
        guard Self.validLocator(locator),
              manifestDigest.count == 32,
              createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds,
              (lastError?.utf8.count ?? 0) <= 4_096,
              restoreResultJSON == nil || restoredSkillID != nil else {
            throw SkillBackupRecordError.invalidRecord
        }
        if let restoreResultJSON {
            try SkillBackupCanonicalJSON.validate(restoreResultJSON)
        }
        let hasPruneLocator = pruneQuarantineLocator != nil
        let hasPruneIdentity = pruneQuarantineIdentity != nil
        guard hasPruneLocator == hasPruneIdentity,
              pruneQuarantineLocator.map(Self.validLocator) ?? true else {
            throw SkillBackupRecordError.invalidRecord
        }
        switch state {
        case .preparing, .available:
            guard !hasPruneLocator, lastError == nil else {
                throw SkillBackupRecordError.invalidRecord
            }
        case .pruning:
            guard hasPruneLocator, lastError == nil else {
                throw SkillBackupRecordError.invalidRecord
            }
        case .needsRepair:
            guard let lastError, !lastError.isEmpty else {
                throw SkillBackupRecordError.invalidRecord
            }
        }
    }

    private static func transitionAllowed(
        from old: SkillBackupState,
        to new: SkillBackupState
    ) -> Bool {
        if old == new { return true }
        return switch (old, new) {
        case (.preparing, .available), (.preparing, .needsRepair),
             (.available, .pruning), (.available, .needsRepair),
             (.pruning, .needsRepair),
             (.needsRepair, .preparing), (.needsRepair, .available),
             (.needsRepair, .pruning):
            true
        default:
            false
        }
    }

    static func validLocator(_ locator: String) -> Bool {
        guard !locator.isEmpty,
              locator.utf8.count <= 4_096,
              !locator.hasPrefix("/"),
              !locator.contains("\0") else {
            return false
        }
        let components = locator.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
