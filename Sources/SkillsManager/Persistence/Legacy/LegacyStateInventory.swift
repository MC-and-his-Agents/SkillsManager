import CryptoKit
import Darwin
import Foundation

nonisolated final class LegacyStateInventory: @unchecked Sendable {
    static let emptyDigest = Data([
        0x6b, 0x70, 0x0b, 0xf4, 0xc7, 0x7c, 0x44, 0xdd,
        0xbe, 0x80, 0x4b, 0x37, 0x5e, 0x19, 0xa9, 0xcf,
        0xa7, 0x0f, 0xc3, 0xad, 0x84, 0xa1, 0xe5, 0x37,
        0xf6, 0x97, 0xd7, 0xf3, 0xc0, 0x3c, 0xe6, 0x3f,
    ])

    let inventoryDigest: Data
    let entryCount: Int
    let customPathsFilePresent: Bool
    let diagnostics: [LegacyMigrationDiagnostic]
    private let chain: LegacyDirectoryChain
    private let customPathsFile: LegacyCapturedFile?
    private let publishFiles: [LegacyCapturedFile]
    private let publishNames: Set<String>

    static func capture(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        ownership: SSOTWriterOwnership,
        maximumTotalBytes: Int = 64 * 1_024 * 1_024
    ) throws -> LegacyStateInventory {
        guard maximumTotalBytes >= 0 else {
            throw LegacyMigrationFailure(.legacyResourceLimitExceeded)
        }
        try validateOwnership(ownership)
        let chain = try LegacyDirectoryChain.capture(homeURL: homeURL)
        let rootDiagnostics = try ignoredRootEntries(in: chain.legacyRoot)
        let customPathsFile = try captureCustomPaths(
            in: chain.legacyRoot,
            maximumBytes: min(8 * 1_024 * 1_024, maximumTotalBytes)
        )
        let remainingBytes = maximumTotalBytes - (customPathsFile?.bytes.count ?? 0)
        let publishCapture = try capturePublishStates(
            in: chain.skillStateDirectory,
            maximumTotalBytes: remainingBytes
        )
        let publishFiles = publishCapture.files
        let files = ([customPathsFile].compactMap { $0 } + publishFiles).sorted {
            $0.locator.utf8.lexicographicallyPrecedes($1.locator.utf8)
        }
        let digest = migrationDigest(files)
        if files.isEmpty, digest != emptyDigest {
            throw LegacyMigrationFailure(.ledgerConflict)
        }
        return LegacyStateInventory(
            inventoryDigest: digest,
            chain: chain,
            customPathsFile: customPathsFile,
            publishFiles: publishFiles,
            publishNames: Set(publishFiles.map(\.name)),
            diagnostics: (rootDiagnostics + publishCapture.diagnostics).sorted(by: diagnosticOrder)
        )
    }

    func decode() throws -> DecodedLegacyState {
        let customPaths = try customPathsFile.map {
            try LegacyStateWireDecoder.decodeCustomPaths($0.bytes)
        } ?? []
        let publishStates = try publishFiles.map {
            try LegacyStateWireDecoder.decodePublishState(
                $0.bytes,
                locator: $0.locator,
                digest: $0.digest
            )
        }
        return DecodedLegacyState(
            customPathsFilePresent: customPathsFile != nil,
            customPaths: customPaths,
            publishStates: publishStates
        )
    }

    func validateUnchanged(ownership: SSOTWriterOwnership) throws {
        try Self.validateOwnership(ownership)
        try chain.validateUnchanged()
        try validateCustomPathsPresence()
        try validatePublishFileSet()
        try customPathsFile?.validateUnchanged()
        for file in publishFiles { try file.validateUnchanged() }
        try Self.validateOwnership(ownership)
    }

    private init(
        inventoryDigest: Data,
        chain: LegacyDirectoryChain,
        customPathsFile: LegacyCapturedFile?,
        publishFiles: [LegacyCapturedFile],
        publishNames: Set<String>,
        diagnostics: [LegacyMigrationDiagnostic]
    ) {
        self.inventoryDigest = inventoryDigest
        self.entryCount = (customPathsFile == nil ? 0 : 1) + publishFiles.count
        self.customPathsFilePresent = customPathsFile != nil
        self.chain = chain
        self.customPathsFile = customPathsFile
        self.publishFiles = publishFiles
        self.publishNames = publishNames
        self.diagnostics = diagnostics
    }

    private func validateCustomPathsPresence() throws {
        guard let root = chain.legacyRoot else { return }
        var metadata = stat()
        let exists = Darwin.fstatat(root.value, "custom-paths.json", &metadata, AT_SYMLINK_NOFOLLOW) == 0
        if !exists, errno != ENOENT { throw LegacyMigrationFailure(.legacyPathChanged) }
        let isRegularFile = exists
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        guard isRegularFile == (customPathsFile != nil) else {
            throw LegacyMigrationFailure(.legacyInventoryChanged, locator: "custom-paths.json")
        }
    }

    private func validatePublishFileSet() throws {
        guard let directory = chain.skillStateDirectory else { return }
        let current = Set(try Self.publishCandidates(in: directory).names)
        guard current == publishNames else {
            throw LegacyMigrationFailure(.legacyInventoryChanged)
        }
    }

    private static func captureCustomPaths(
        in root: LegacyHeldDescriptor?,
        maximumBytes: Int
    ) throws -> LegacyCapturedFile? {
        guard let root else { return nil }
        var metadata = stat()
        guard Darwin.fstatat(root.value, "custom-paths.json", &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw LegacyMigrationFailure(.legacyPathChanged, locator: "custom-paths.json")
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return try LegacyCapturedFile(
            locator: "custom-paths.json",
            name: "custom-paths.json",
            parent: root,
            maximumBytes: maximumBytes
        )
    }

    private static func capturePublishStates(
        in directory: LegacyHeldDescriptor?,
        maximumTotalBytes: Int
    ) throws -> (files: [LegacyCapturedFile], diagnostics: [LegacyMigrationDiagnostic]) {
        guard let directory else { return ([], []) }
        let candidates = try publishCandidates(in: directory)
        let names = candidates.names
        guard names.count <= 10_000 else {
            throw LegacyMigrationFailure(.legacyResourceLimitExceeded)
        }
        var collisionKeys = Set<String>()
        var files: [LegacyCapturedFile] = []
        var remainingBytes = maximumTotalBytes
        for name in names {
            let normalizedName = name.precomposedStringWithCanonicalMapping
            let locator = "skill-state/\(normalizedName)"
            guard 1...512 ~= locator.utf8.count else {
                throw LegacyMigrationFailure(.legacyResourceLimitExceeded, locator: locator)
            }
            let collisionKey = locator.folding(options: [.caseInsensitive], locale: nil)
            guard collisionKeys.insert(collisionKey).inserted else {
                throw LegacyMigrationFailure(.legacyDuplicateRecord, locator: locator)
            }
            let file = try LegacyCapturedFile(
                locator: locator,
                name: name,
                parent: directory,
                maximumBytes: min(1 * 1_024 * 1_024, remainingBytes)
            )
            remainingBytes -= file.bytes.count
            files.append(file)
        }
        return (
            files.sorted { $0.locator.utf8.lexicographicallyPrecedes($1.locator.utf8) },
            candidates.diagnostics
        )
    }

    private static func publishCandidates(
        in directory: LegacyHeldDescriptor
    ) throws -> (names: [String], diagnostics: [LegacyMigrationDiagnostic]) {
        var names: [String] = []
        var diagnostics: [LegacyMigrationDiagnostic] = []
        for name in try legacyDirectoryNames(directory).sorted() {
            var metadata = stat()
            guard Darwin.fstatat(directory.value, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw LegacyMigrationFailure(.legacyInventoryChanged)
            }
            if name.hasSuffix(".json"), metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                names.append(name)
            } else {
                diagnostics.append(ignoredDiagnostic(locator: "skill-state/\(name)"))
            }
        }
        return (names, diagnostics)
    }

    private static func ignoredRootEntries(
        in root: LegacyHeldDescriptor?
    ) throws -> [LegacyMigrationDiagnostic] {
        guard let root else { return [] }
        var diagnostics: [LegacyMigrationDiagnostic] = []
        for name in try legacyDirectoryNames(root).sorted() {
            if name == "skill-state" { continue }
            if name == "custom-paths.json" {
                var metadata = stat()
                guard Darwin.fstatat(root.value, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw LegacyMigrationFailure(.legacyInventoryChanged)
                }
                if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) { continue }
            }
            diagnostics.append(ignoredDiagnostic(locator: name))
        }
        return diagnostics
    }

    private static func ignoredDiagnostic(locator: String) -> LegacyMigrationDiagnostic {
        LegacyMigrationDiagnostic(
            code: .ignoredLegacyEntry,
            locator: locator.precomposedStringWithCanonicalMapping
        )
    }

    private static func diagnosticOrder(
        _ lhs: LegacyMigrationDiagnostic,
        _ rhs: LegacyMigrationDiagnostic
    ) -> Bool {
        (lhs.locator ?? "").utf8.lexicographicallyPrecedes((rhs.locator ?? "").utf8)
    }

    private static func migrationDigest(_ files: [LegacyCapturedFile]) -> Data {
        var payload = Data("SkillsManager.LegacyMigrationInventory.v1".utf8)
        payload.append(0)
        appendUInt64(UInt64(files.count), to: &payload)
        for file in files {
            let locator = Data(file.locator.utf8)
            appendUInt64(UInt64(locator.count), to: &payload)
            payload.append(locator)
            appendUInt64(UInt64(file.bytes.count), to: &payload)
            payload.append(file.bytes)
        }
        return Data(SHA256.hash(data: payload))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    static func validateOwnership(_ ownership: SSOTWriterOwnership) throws {
        do {
            try ownership.validateForMutation()
        } catch {
            throw LegacyMigrationFailure(.ownershipUnavailable)
        }
    }
}
