import CryptoKit
import Darwin
import Foundation

nonisolated struct SkillBackupPublication: Sendable {
    let locator: String
    let identity: ManagedItemIdentity
    let manifestDigest: Data
    let contentFingerprint: SkillContentFingerprint
}

nonisolated struct ValidatedSkillBackup: Sendable {
    let snapshot: SkillContentSnapshot
    let manifestBytes: Data
    let identity: ManagedItemIdentity
}

nonisolated struct SkillBackupPruneObservation: Sendable {
    let finalIdentity: ManagedItemIdentity?
    let quarantineIdentity: ManagedItemIdentity?
}

nonisolated enum SkillBackupFileSystemError: LocalizedError, Equatable {
    case invalidLocator
    case destinationExists
    case contentChanged
    case manifestChanged
    case itemChanged
    case preparedContentMissing
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidLocator: "The backup locator is invalid."
        case .destinationExists: "The backup destination already exists."
        case .contentChanged: "The backup content does not match its recorded fingerprint."
        case .manifestChanged: "The backup manifest does not match its recorded digest."
        case .itemChanged: "The backup changed during the operation."
        case .preparedContentMissing: "The prepared backup content is missing."
        case .posix(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Descriptor-anchored backup storage below the already verified management root.
nonisolated final class SkillBackupFileSystem {
    private static let rootName = "skill-backups"
    static let filesName = "skill-files"
    static let manifestName = "manifest.json"

    let managementRoot: VerifiedSSOTRoot
    let ownership: SSOTWriterOwnership
    let limits: SkillContentLimits
    let backupRoot: VerifiedSSOTRoot
    private let backupGuard: ManagedPathGuard

    init(
        managementRoot: VerifiedSSOTRoot,
        ownership: SSOTWriterOwnership,
        limits: SkillContentLimits = .default
    ) throws {
        try ownership.validateForMutation()
        self.managementRoot = managementRoot
        self.ownership = ownership
        self.limits = limits
        let managementGuard = try ManagedPathGuard(verifiedRoot: managementRoot)
        let url = managementRoot.url.appendingPathComponent(Self.rootName, isDirectory: true)
        backupRoot = try Self.openOrCreateRoot(
            url: url,
            in: managementGuard,
            validateAuthority: {
                try managementRoot.revalidate()
                try ownership.validateForMutation()
            }
        )
        backupGuard = try ManagedPathGuard(verifiedRoot: backupRoot)
    }

    func publish(
        snapshot: SkillContentSnapshot,
        skillID: SkillID,
        backupID: UUID,
        createdAtMilliseconds: Int64,
        manifestBytes: Data,
        expectedFingerprint: SkillContentFingerprint,
        beforePromotion: (SkillBackupPublication) throws -> Void,
        afterPreparationRecorded: () throws -> Void,
        afterPromotion: () throws -> Void
    ) throws -> SkillBackupPublication {
        guard createdAtMilliseconds >= 0,
              snapshot.fingerprintDigest == expectedFingerprint.digest else {
            throw SkillBackupFileSystemError.contentChanged
        }
        try validateAuthority()
        let (skillRoot, skillGuard) = try openOrCreateSkillRoot(skillID)
        let backupName = "\(createdAtMilliseconds)-\(backupID.uuidString.lowercased())"
        let stagingName = ".skillsmanager-backup-\(backupID.uuidString.lowercased()).tmp"
        let stagingURL = skillRoot.url.appendingPathComponent(stagingName, isDirectory: true)
        let finalURL = skillRoot.url.appendingPathComponent(backupName, isDirectory: true)
        guard try skillGuard.itemIdentity(at: stagingURL) == nil,
              try skillGuard.itemIdentity(at: finalURL) == nil else {
            throw SkillBackupFileSystemError.destinationExists
        }

        let staging = try skillGuard.createDirectory(
            at: stagingURL,
            afterTemporaryCreate: { _ in try self.validateAuthority() },
            afterCreate: { try self.validateAuthority() },
            admitFailureCleanup: { try self.validateAuthority() }
        )
        var preparationRecorded = false
        do {
            try stageBackupContents(
                snapshot: snapshot,
                stagingDescriptor: staging.descriptor,
                finalURL: finalURL,
                manifestBytes: manifestBytes,
                expectedFingerprint: expectedFingerprint
            )
            let publication = SkillBackupPublication(
                locator: "\(skillID.directoryName)/\(backupName)",
                identity: staging.identity,
                manifestDigest: Data(SHA256.hash(data: manifestBytes)),
                contentFingerprint: expectedFingerprint
            )
            try beforePromotion(publication)
            preparationRecorded = true
            try afterPreparationRecorded()
            try skillGuard.promoteStagedItemIfAbsent(
                at: stagingURL,
                to: finalURL,
                expectedStaged: staging.identity
            ) { descriptor in
                try self.validatePublishedDirectory(
                    descriptor,
                    expectedManifestDigest: publication.manifestDigest,
                    expectedFingerprint: expectedFingerprint
                )
            }
            try SSOTDurability.syncDirectory(skillGuard.rootDescriptor)
            try afterPromotion()
            try skillRoot.revalidate()
            guard let identity = try skillGuard.itemIdentity(at: finalURL) else {
                throw SkillBackupFileSystemError.itemChanged
            }
            _ = try validate(
                locator: "\(skillID.directoryName)/\(backupName)",
                expectedIdentity: identity,
                expectedManifestDigest: Data(SHA256.hash(data: manifestBytes)),
                expectedFingerprint: expectedFingerprint
            )
            return publication
        } catch {
            if !preparationRecorded,
               (try? skillGuard.itemIdentity(at: stagingURL)) == staging.identity {
                try? skillGuard.removeItem(at: stagingURL, expectedIdentity: staging.identity)
                try? SSOTDurability.syncDirectory(skillGuard.rootDescriptor)
            }
            throw error
        }
    }

    func ensurePublished(
        backupID: UUID,
        publication: SkillBackupPublication
    ) throws {
        let components = try locatorComponents(publication.locator)
        let skillID = try skillID(from: components.skill)
        let (skillRoot, skillGuard) = try openSkillRoot(skillID)
        let finalURL = skillRoot.url.appendingPathComponent(components.item, isDirectory: true)
        let stagingURL = skillRoot.url.appendingPathComponent(
            ".skillsmanager-backup-\(backupID.uuidString.lowercased()).tmp",
            isDirectory: true
        )
        let finalIdentity = try skillGuard.itemIdentity(at: finalURL)
        let stagingIdentity = try skillGuard.itemIdentity(at: stagingURL)
        switch (finalIdentity, stagingIdentity) {
        case (publication.identity, nil):
            break
        case (nil, publication.identity):
            try skillGuard.promoteStagedItemIfAbsent(
                at: stagingURL,
                to: finalURL,
                expectedStaged: publication.identity
            ) { descriptor in
                try self.validatePublishedDirectory(
                    descriptor,
                    expectedManifestDigest: publication.manifestDigest,
                    expectedFingerprint: publication.contentFingerprint
                )
            }
            try SSOTDurability.syncDirectory(skillGuard.rootDescriptor)
        case (nil, nil):
            throw SkillBackupFileSystemError.preparedContentMissing
        default:
            throw SkillBackupFileSystemError.itemChanged
        }
        _ = try validate(
            locator: publication.locator,
            expectedIdentity: publication.identity,
            expectedManifestDigest: publication.manifestDigest,
            expectedFingerprint: publication.contentFingerprint
        )
    }

    func validate(
        locator: String,
        expectedIdentity: ManagedItemIdentity,
        expectedManifestDigest: Data,
        expectedFingerprint: SkillContentFingerprint
    ) throws -> ValidatedSkillBackup {
        let components = try locatorComponents(locator)
        let skillID = try skillID(from: components.skill)
        let (skillRoot, skillGuard) = try openSkillRoot(skillID)
        let finalURL = skillRoot.url.appendingPathComponent(components.item, isDirectory: true)
        guard try skillGuard.itemIdentity(at: finalURL) == expectedIdentity else {
            throw SkillBackupFileSystemError.itemChanged
        }
        return try skillGuard.withItemDescriptor(
            at: finalURL,
            expectedIdentity: expectedIdentity
        ) { descriptor in
            let manifestBytes = try readFile(named: Self.manifestName, in: descriptor)
            guard Data(SHA256.hash(data: manifestBytes)) == expectedManifestDigest else {
                throw SkillBackupFileSystemError.manifestChanged
            }
            let filesDescriptor = try openDirectory(named: Self.filesName, in: descriptor)
            defer { Darwin.close(filesDescriptor) }
            let snapshot = try SkillContentSnapshot.capture(
                directoryDescriptor: filesDescriptor,
                displayPath: finalURL.appendingPathComponent(Self.filesName).path,
                limits: limits,
                checkpoint: { try self.validateAuthority() }
            )
            guard snapshot.fingerprintDigest == expectedFingerprint.digest else {
                throw SkillBackupFileSystemError.contentChanged
            }
            return ValidatedSkillBackup(
                snapshot: snapshot,
                manifestBytes: manifestBytes,
                identity: expectedIdentity
            )
        }
    }

    func quarantineForPruning(
        locator: String,
        expectedIdentity: ManagedItemIdentity,
        backupID: UUID
    ) throws -> String {
        let components = try locatorComponents(locator)
        let skillID = try skillID(from: components.skill)
        let (skillRoot, skillGuard) = try openSkillRoot(skillID)
        let finalURL = skillRoot.url.appendingPathComponent(components.item, isDirectory: true)
        let quarantineName = ".skillsmanager-prune-\(backupID.uuidString.lowercased())"
        let quarantineURL = skillRoot.url.appendingPathComponent(
            quarantineName,
            isDirectory: true
        )
        guard try skillGuard.itemIdentity(at: finalURL) == expectedIdentity,
              try skillGuard.itemIdentity(at: quarantineURL) == nil else {
            throw SkillBackupFileSystemError.itemChanged
        }
        let finalName = try skillGuard.managedName(for: finalURL).value
        try validateAuthority()
        guard Darwin.renameatx_np(
            skillGuard.rootDescriptor,
            finalName,
            skillGuard.rootDescriptor,
            quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST { throw SkillBackupFileSystemError.destinationExists }
            throw posix("quarantine backup for pruning")
        }
        try SSOTDurability.syncDirectory(skillGuard.rootDescriptor)
        guard try skillGuard.itemIdentity(at: quarantineURL) == expectedIdentity,
              try skillGuard.itemIdentity(at: finalURL) == nil else {
            throw SkillBackupFileSystemError.itemChanged
        }
        return "\(components.skill)/\(quarantineName)"
    }

    func removePruningQuarantine(
        locator: String,
        expectedIdentity: ManagedItemIdentity
    ) throws {
        let components = try locatorComponents(locator)
        let skillID = try skillID(from: components.skill)
        let (skillRoot, skillGuard) = try openSkillRoot(skillID)
        let url = skillRoot.url.appendingPathComponent(components.item, isDirectory: true)
        try skillGuard.removeItem(at: url, expectedIdentity: expectedIdentity)
        try SSOTDurability.syncDirectory(skillGuard.rootDescriptor)
        guard try skillGuard.itemIdentity(at: url) == nil else {
            throw SkillBackupFileSystemError.itemChanged
        }
    }

    func pruneObservation(
        finalLocator: String,
        quarantineLocator: String,
        expectedIdentity: ManagedItemIdentity
    ) throws -> SkillBackupPruneObservation {
        let final = try locatorIdentity(finalLocator)
        let quarantine = try locatorIdentity(quarantineLocator)
        guard final.map({ $0 == expectedIdentity }) ?? true,
              quarantine.map({ $0 == expectedIdentity }) ?? true else {
            throw SkillBackupFileSystemError.itemChanged
        }
        return SkillBackupPruneObservation(
            finalIdentity: final,
            quarantineIdentity: quarantine
        )
    }

    private func openOrCreateSkillRoot(
        _ skillID: SkillID
    ) throws -> (VerifiedSSOTRoot, ManagedPathGuard) {
        let url = backupRoot.url.appendingPathComponent(skillID.directoryName, isDirectory: true)
        let root = try Self.openOrCreateRoot(
            url: url,
            in: backupGuard,
            validateAuthority: validateAuthority
        )
        return (root, try ManagedPathGuard(verifiedRoot: root))
    }

    private func openSkillRoot(
        _ skillID: SkillID
    ) throws -> (VerifiedSSOTRoot, ManagedPathGuard) {
        let url = backupRoot.url.appendingPathComponent(skillID.directoryName, isDirectory: true)
        guard let identity = try backupGuard.itemIdentity(at: url) else {
            throw SkillBackupFileSystemError.itemChanged
        }
        let root = try backupGuard.withItemDescriptor(at: url, expectedIdentity: identity) {
            try VerifiedSSOTRoot(existingRootURL: url, descriptor: $0)
        }
        return (root, try ManagedPathGuard(verifiedRoot: root))
    }

    private static func openOrCreateRoot(
        url: URL,
        in guardValue: ManagedPathGuard,
        validateAuthority: () throws -> Void
    ) throws -> VerifiedSSOTRoot {
        if let identity = try guardValue.itemIdentity(at: url) {
            return try guardValue.withItemDescriptor(at: url, expectedIdentity: identity) {
                try VerifiedSSOTRoot(existingRootURL: url, descriptor: $0)
            }
        }
        let handle = try guardValue.createDirectory(
            at: url,
            afterTemporaryCreate: { _ in try validateAuthority() },
            afterCreate: validateAuthority,
            admitFailureCleanup: validateAuthority
        )
        try SSOTDurability.syncDirectory(guardValue.rootDescriptor)
        return try VerifiedSSOTRoot(existingRootURL: url, descriptor: handle.descriptor)
    }

    private func locatorIdentity(_ locator: String) throws -> ManagedItemIdentity? {
        let components = try locatorComponents(locator)
        let skillID = try skillID(from: components.skill)
        let (skillRoot, skillGuard) = try openSkillRoot(skillID)
        return try skillGuard.itemIdentity(
            at: skillRoot.url.appendingPathComponent(components.item, isDirectory: true)
        )
    }

    private func locatorComponents(_ locator: String) throws -> (skill: String, item: String) {
        guard !locator.hasPrefix("/") else { throw SkillBackupFileSystemError.invalidLocator }
        let components = locator.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SkillBackupFileSystemError.invalidLocator
        }
        return (String(components[0]), String(components[1]))
    }

    private func skillID(from directoryName: String) throws -> SkillID {
        guard let uuid = UUID(uuidString: directoryName),
              uuid.uuidString.lowercased() == directoryName else {
            throw SkillBackupFileSystemError.invalidLocator
        }
        return SkillID(uuid)
    }

    func validateAuthority() throws {
        try managementRoot.revalidate()
        try backupRoot.revalidate()
        try ownership.validateForMutation()
    }
}
