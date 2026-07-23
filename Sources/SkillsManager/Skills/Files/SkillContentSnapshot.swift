import CryptoKit
import Darwin
import Foundation

nonisolated struct SkillContentLimits: Equatable, Sendable {
    static let `default` = SkillContentLimits(
        maximumFileCount: 10_000,
        maximumTotalByteCount: 512 * 1_024 * 1_024,
        maximumFileByteCount: 128 * 1_024 * 1_024,
        maximumDirectoryCount: 10_000,
        maximumPathDepth: 64
    )

    let maximumFileCount: Int
    let maximumTotalByteCount: UInt64
    let maximumFileByteCount: UInt64
    let maximumDirectoryCount: Int
    let maximumPathDepth: Int

    init(
        maximumFileCount: Int,
        maximumTotalByteCount: UInt64,
        maximumFileByteCount: UInt64,
        maximumDirectoryCount: Int = SkillContentLimits.default.maximumDirectoryCount,
        maximumPathDepth: Int = SkillContentLimits.default.maximumPathDepth
    ) {
        self.maximumFileCount = maximumFileCount
        self.maximumTotalByteCount = maximumTotalByteCount
        self.maximumFileByteCount = maximumFileByteCount
        self.maximumDirectoryCount = maximumDirectoryCount
        self.maximumPathDepth = maximumPathDepth
    }
}

typealias SkillCancellationCheckpoint = () throws -> Void

nonisolated struct SkillContentSnapshot: Equatable, Sendable {
    static let fingerprintAlgorithmVersion = 1

    struct File: Equatable, Sendable {
        let relativePath: String
        let byteCount: UInt64
    }

    struct Statistics: Equatable, Sendable {
        let fileCount: Int
        let totalByteCount: UInt64
    }

    let fingerprintDigest: Data
    var fingerprint: String {
        fingerprintDigest.map { String(format: "%02x", $0) }.joined()
    }
    let files: [File]
    let statistics: Statistics
    let sourceTree: SafeSourceTree
    let sourceDirectories: [SafeSourceTree.DirectoryRecord]
    let discoveredFiles: [SkillContentFileEnumerator.DiscoveredFile]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fingerprint == rhs.fingerprint
            && lhs.files == rhs.files
            && lhs.statistics == rhs.statistics
    }

    nonisolated static func capture(
        at rootURL: URL,
        limits: SkillContentLimits = .default,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> SkillContentSnapshot {
        try checkpoint()
        let sourceTree = try SafeSourceTree(rootURL: rootURL)
        return try capture(sourceTree: sourceTree, limits: limits, checkpoint: checkpoint)
    }

    nonisolated static func capture(
        directoryDescriptor: Int32,
        displayPath: String,
        limits: SkillContentLimits = .default,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> SkillContentSnapshot {
        try checkpoint()
        let sourceTree = try SafeSourceTree(
            directoryDescriptor: directoryDescriptor,
            displayPath: displayPath
        )
        return try capture(sourceTree: sourceTree, limits: limits, checkpoint: checkpoint)
    }

    private nonisolated static func capture(
        sourceTree: SafeSourceTree,
        limits: SkillContentLimits,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> SkillContentSnapshot {
        let discovery = try SkillContentFileEnumerator(limits: limits).files(
            in: sourceTree,
            checkpoint: checkpoint
        )
        let discoveredFiles = discovery.files
        var hasher = SHA256()
        hasher.update(data: Data("SkillsManager.SkillContentSnapshot".utf8))
        hasher.update(bigEndian: UInt32(fingerprintAlgorithmVersion))

        for file in discoveredFiles {
            try checkpoint()
            let pathBytes = Data(file.relativePath.utf8)
            hasher.update(bigEndian: UInt64(pathBytes.count))
            hasher.update(data: pathBytes)
            hasher.update(bigEndian: file.byteCount)
            try hashFile(
                file,
                sourceTree: discovery.sourceTree,
                into: &hasher,
                checkpoint: checkpoint
            )
        }
        try discovery.sourceTree.verifyDirectories(
            discovery.directories,
            checkpoint: checkpoint
        )

        let files = discoveredFiles.map {
            File(relativePath: $0.relativePath, byteCount: $0.byteCount)
        }
        let totalByteCount = files.reduce(UInt64.zero) { $0 + $1.byteCount }
        let fingerprintDigest = Data(hasher.finalize())
        return SkillContentSnapshot(
            fingerprintDigest: fingerprintDigest,
            files: files,
            statistics: Statistics(fileCount: files.count, totalByteCount: totalByteCount),
            sourceTree: discovery.sourceTree,
            sourceDirectories: discovery.directories,
            discoveredFiles: discoveredFiles
        )
    }

    private nonisolated static func hashFile(
        _ file: SkillContentFileEnumerator.DiscoveredFile,
        sourceTree: SafeSourceTree,
        into hasher: inout SHA256,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        let descriptor = try openValidatedSource(file, sourceTree: sourceTree)
        defer { Darwin.close(descriptor) }

        var bytesRead = UInt64.zero
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkpoint()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw SkillContentSnapshotError.fileSystemFailure(
                    path: file.relativePath,
                    code: errno
                )
            }
            if count == 0 { break }

            bytesRead += UInt64(count)
            guard bytesRead <= file.byteCount else {
                throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }

        guard bytesRead == file.byteCount else {
            throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
        }
        try verifyFinalSource(descriptor, file: file)
    }

    nonisolated func readUTF8File(
        relativePath: String,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws -> String {
        try checkpoint()
        guard let file = discoveredFiles.first(where: { $0.relativePath == relativePath }) else {
            throw SkillContentSnapshotError.fileNotFound(path: relativePath)
        }
        let descriptor = try Self.openValidatedSource(file, sourceTree: sourceTree)
        defer { Darwin.close(descriptor) }

        var data = Data()
        var bytesRead = UInt64.zero
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkpoint()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw SkillContentSnapshotError.fileSystemFailure(path: relativePath, code: errno)
            }
            if count == 0 { break }

            bytesRead += UInt64(count)
            guard bytesRead <= file.byteCount else {
                throw SkillContentSnapshotError.fileChanged(path: relativePath)
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        guard bytesRead == file.byteCount else {
            throw SkillContentSnapshotError.fileChanged(path: relativePath)
        }
        try Self.verifyFinalSource(descriptor, file: file)
        guard let value = String(data: data, encoding: .utf8) else {
            throw SkillContentSnapshotError.invalidUTF8(path: relativePath)
        }
        return value
    }

    nonisolated static func openValidatedSource(
        _ file: SkillContentFileEnumerator.DiscoveredFile,
        sourceTree: SafeSourceTree
    ) throws -> Int32 {
        let descriptor = try sourceTree.openFile(file)
        var finalMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SkillContentSnapshotError.fileSystemFailure(
                path: file.relativePath,
                code: code
            )
        }
        guard matches(finalMetadata, file: file) else {
            Darwin.close(descriptor)
            throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
        }
        return descriptor
    }

    nonisolated static func verifyFinalSource(
        _ descriptor: Int32,
        file: SkillContentFileEnumerator.DiscoveredFile
    ) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: file.relativePath, code: errno)
        }
        guard matches(metadata, file: file) else {
            throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
        }
    }

    private nonisolated static func matches(
        _ metadata: stat,
        file: SkillContentFileEnumerator.DiscoveredFile
    ) -> Bool {
        SkillContentFileEnumerator.kind(of: metadata) == .regularFile
            && metadata.st_size >= 0
            && UInt64(metadata.st_size) == file.byteCount
            && metadata.st_dev == file.device
            && metadata.st_ino == file.inode
            && metadata.st_gen == file.generation
            && metadata.st_mtimespec.tv_sec == file.modificationSeconds
            && metadata.st_mtimespec.tv_nsec == file.modificationNanoseconds
            && metadata.st_ctimespec.tv_sec == file.statusChangeSeconds
            && metadata.st_ctimespec.tv_nsec == file.statusChangeNanoseconds
    }
}

nonisolated enum SkillContentSnapshotError: LocalizedError, Equatable, Sendable {
    case rootIsNotDirectory(path: String)
    case unsupportedEntry(path: String)
    case pathCollision(first: String, second: String)
    case fileCountLimitExceeded(limit: Int)
    case directoryCountLimitExceeded(limit: Int)
    case pathDepthLimitExceeded(path: String, limit: Int)
    case fileByteLimitExceeded(path: String, limit: UInt64, actual: UInt64)
    case totalByteLimitExceeded(limit: UInt64, actual: UInt64)
    case fileNotFound(path: String)
    case invalidUTF8(path: String)
    case fileChanged(path: String)
    case fileSystemFailure(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .rootIsNotDirectory:
            "The selected Skill must be a regular directory."
        case .unsupportedEntry(let path):
            "The Skill contains an unsupported file or symbolic link: \(path)"
        case .pathCollision(let first, let second):
            "The Skill contains conflicting paths: \(first) and \(second)"
        case .fileCountLimitExceeded(let limit):
            "The Skill contains more than \(limit) files."
        case .directoryCountLimitExceeded(let limit):
            "The Skill contains more than \(limit) directories."
        case .pathDepthLimitExceeded(let path, let limit):
            "The path \(path) exceeds the \(limit)-component depth limit."
        case .fileByteLimitExceeded(let path, let limit, _):
            "The file \(path) exceeds the \(limit)-byte limit."
        case .totalByteLimitExceeded(let limit, _):
            "The Skill exceeds the \(limit)-byte total size limit."
        case .fileNotFound(let path):
            "The Skill snapshot does not contain \(path)."
        case .invalidUTF8(let path):
            "The file \(path) is not valid UTF-8."
        case .fileChanged(let path):
            "The file changed while it was being read: \(path)"
        case .fileSystemFailure(let path, let code):
            "Unable to read \(path): \(String(cString: strerror(code)))"
        }
    }
}

nonisolated enum SkillContentExclusions {
    private static let names: Set<String> = [
        ".git",
        ".clawdhub",
        ".skillsmanager",
        ".ds_store",
        ".skillsmanager.json",
    ]
    private static let temporaryNamePrefix = ".skillsmanager-tmp-"

    nonisolated static func contains(_ name: String, isDirectory _: Bool) -> Bool {
        let key = SkillContentPath.collisionKey(for: name)
        if names.contains(key) { return true }
        return key.hasPrefix(temporaryNamePrefix)
    }
}

nonisolated enum SkillContentPath {
    nonisolated static func normalizedComponent(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping
    }

    nonisolated static func visibleDirectoryName(_ component: String) -> String? {
        let normalized = normalizedComponent(component)
        guard !normalized.isEmpty,
              normalized != ".",
              normalized != "..",
              !normalized.hasPrefix("."),
              !normalized.contains("/"),
              !normalized.contains("\\"),
              !normalized.contains("\0") else {
            return nil
        }
        return normalized
    }

    nonisolated static func collisionKey(for component: String) -> String {
        normalizedComponent(component).folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    nonisolated static func namesAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        collisionKey(for: lhs) == collisionKey(for: rhs)
    }

    nonisolated static func uniqueNormalizedComponents(_ components: [String]) throws -> [String] {
        var firstNameByKey: [String: String] = [:]
        return try components.map { component in
            let normalized = normalizedComponent(component)
            let key = collisionKey(for: normalized)
            if let first = firstNameByKey[key] {
                throw SkillContentSnapshotError.pathCollision(first: first, second: component)
            }
            firstNameByKey[key] = component
            return normalized
        }
    }
}

private extension SHA256 {
    mutating nonisolated func update<T: FixedWidthInteger>(bigEndian value: T) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { update(data: Data($0)) }
    }
}
