import CryptoKit
import Darwin
import Foundation

nonisolated struct SkillContentLimits: Equatable, Sendable {
    static let `default` = SkillContentLimits(
        maximumFileCount: 10_000,
        maximumTotalByteCount: 512 * 1_024 * 1_024,
        maximumFileByteCount: 128 * 1_024 * 1_024
    )

    let maximumFileCount: Int
    let maximumTotalByteCount: UInt64
    let maximumFileByteCount: UInt64
}

typealias SkillCancellationCheckpoint = () throws -> Void

nonisolated struct SkillContentSnapshot: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let relativePath: String
        let byteCount: UInt64
    }

    struct Statistics: Equatable, Sendable {
        let fileCount: Int
        let totalByteCount: UInt64
    }

    let fingerprint: String
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
        let discovery = try SkillContentFileEnumerator(limits: limits).files(
            at: rootURL,
            checkpoint: checkpoint
        )
        let discoveredFiles = discovery.files
        var hasher = SHA256()
        hasher.update(data: Data("SkillsManager.SkillContentSnapshot".utf8))
        hasher.update(bigEndian: UInt32(1))

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
        return SkillContentSnapshot(
            fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
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
    case fileByteLimitExceeded(path: String, limit: UInt64, actual: UInt64)
    case totalByteLimitExceeded(limit: UInt64, actual: UInt64)
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
        case .fileByteLimitExceeded(let path, let limit, _):
            "The file \(path) exceeds the \(limit)-byte limit."
        case .totalByteLimitExceeded(let limit, _):
            "The Skill exceeds the \(limit)-byte total size limit."
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

    nonisolated static func collisionKey(for component: String) -> String {
        normalizedComponent(component).folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
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

nonisolated struct SkillContentFileEnumerator {
    enum EntryKind {
        case directory
        case regularFile
        case unsupported
    }

    struct DiscoveredFile: Sendable {
        let directorySteps: [SafeSourceTree.DirectoryStep]
        let fileName: String
        let relativePath: String
        let byteCount: UInt64
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
        let modificationSeconds: time_t
        let modificationNanoseconds: Int
        let statusChangeSeconds: time_t
        let statusChangeNanoseconds: Int
        let safePermissions: mode_t
    }

    struct Discovery: Sendable {
        let sourceTree: SafeSourceTree
        let files: [DiscoveredFile]
        let directories: [SafeSourceTree.DirectoryRecord]
    }

    let limits: SkillContentLimits

    nonisolated func files(
        at rootURL: URL,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> Discovery {
        try checkpoint()
        let sourceTree = try SafeSourceTree(rootURL: rootURL)
        let rootDescriptor = try sourceTree.duplicateRoot()
        defer { Darwin.close(rootDescriptor) }
        var files: [DiscoveredFile] = []
        var directories: [SafeSourceTree.DirectoryRecord] = []
        var totalByteCount = UInt64.zero
        try collectFiles(
            in: rootDescriptor,
            directorySteps: [],
            normalizedParentComponents: [],
            files: &files,
            directories: &directories,
            totalByteCount: &totalByteCount,
            checkpoint: checkpoint
        )
        files.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        return Discovery(sourceTree: sourceTree, files: files, directories: directories)
    }

    private nonisolated func collectFiles(
        in directoryDescriptor: Int32,
        directorySteps: [SafeSourceTree.DirectoryStep],
        normalizedParentComponents: [String],
        files: inout [DiscoveredFile],
        directories: inout [SafeSourceTree.DirectoryRecord],
        totalByteCount: inout UInt64,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        try checkpoint()
        let displayPath = normalizedParentComponents.joined(separator: "/")
        let sortedNames = try SafeSourceTree.names(
            in: directoryDescriptor,
            displayPath: displayPath
        ).sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        let normalizedNames = try SkillContentPath.uniqueNormalizedComponents(
            sortedNames
        )

        for (rawName, normalizedName) in zip(sortedNames, normalizedNames) {
            try checkpoint()
            let components = normalizedParentComponents + [normalizedName]
            let relativePath = components.joined(separator: "/")
            let childMetadata = try metadata(
                named: rawName,
                in: directoryDescriptor,
                displayPath: relativePath
            )
            let kind = Self.kind(of: childMetadata)

            if SkillContentExclusions.contains(normalizedName, isDirectory: kind == .directory) {
                continue
            }
            guard kind != .unsupported else {
                throw SkillContentSnapshotError.unsupportedEntry(path: relativePath)
            }

            if kind == .directory {
                let identity = SafeSourceTree.Identity(childMetadata)
                let childSteps = directorySteps + [.init(name: rawName, identity: identity)]
                directories.append(.init(steps: childSteps, relativePath: relativePath))
                let childDescriptor = try SafeSourceTree.openDirectory(
                    named: rawName,
                    in: directoryDescriptor,
                    expectedIdentity: identity,
                    displayPath: relativePath
                )
                do {
                    defer { Darwin.close(childDescriptor) }
                    try collectFiles(
                        in: childDescriptor,
                        directorySteps: childSteps,
                        normalizedParentComponents: components,
                        files: &files,
                        directories: &directories,
                        totalByteCount: &totalByteCount,
                        checkpoint: checkpoint
                    )
                }
                continue
            }

            try appendFile(
                named: rawName,
                directorySteps: directorySteps,
                relativePath: relativePath,
                metadata: childMetadata,
                to: &files,
                totalByteCount: &totalByteCount
            )
        }
    }

    private nonisolated func appendFile(
        named fileName: String,
        directorySteps: [SafeSourceTree.DirectoryStep],
        relativePath: String,
        metadata: stat,
        to files: inout [DiscoveredFile],
        totalByteCount: inout UInt64
    ) throws {
        guard metadata.st_size >= 0 else {
            throw SkillContentSnapshotError.fileChanged(path: relativePath)
        }
        let byteCount = UInt64(metadata.st_size)
        guard byteCount <= limits.maximumFileByteCount else {
            throw SkillContentSnapshotError.fileByteLimitExceeded(
                path: relativePath,
                limit: limits.maximumFileByteCount,
                actual: byteCount
            )
        }
        guard files.count < limits.maximumFileCount else {
            throw SkillContentSnapshotError.fileCountLimitExceeded(limit: limits.maximumFileCount)
        }
        let (newTotal, overflow) = totalByteCount.addingReportingOverflow(byteCount)
        guard !overflow, newTotal <= limits.maximumTotalByteCount else {
            throw SkillContentSnapshotError.totalByteLimitExceeded(
                limit: limits.maximumTotalByteCount,
                actual: overflow ? UInt64.max : newTotal
            )
        }

        totalByteCount = newTotal
        files.append(
            DiscoveredFile(
                directorySteps: directorySteps,
                fileName: fileName,
                relativePath: relativePath,
                byteCount: byteCount,
                device: metadata.st_dev,
                inode: metadata.st_ino,
                generation: metadata.st_gen,
                modificationSeconds: metadata.st_mtimespec.tv_sec,
                modificationNanoseconds: metadata.st_mtimespec.tv_nsec,
                statusChangeSeconds: metadata.st_ctimespec.tv_sec,
                statusChangeNanoseconds: metadata.st_ctimespec.tv_nsec,
                safePermissions: metadata.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO)
            )
        )
    }

    private nonisolated func metadata(
        named name: String,
        in directoryDescriptor: Int32,
        displayPath: String
    ) throws -> stat {
        var metadata = stat()
        guard Darwin.fstatat(
            directoryDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        return metadata
    }

    nonisolated static func kind(of metadata: stat) -> EntryKind {
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .regularFile
        default: .unsupported
        }
    }
}

private extension SHA256 {
    mutating nonisolated func update<T: FixedWidthInteger>(bigEndian value: T) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { update(data: Data($0)) }
    }
}
