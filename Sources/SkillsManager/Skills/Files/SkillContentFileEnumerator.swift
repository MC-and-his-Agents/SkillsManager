import Darwin
import Foundation

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
        in sourceTree: SafeSourceTree,
        checkpoint: SkillCancellationCheckpoint
    ) throws -> Discovery {
        try checkpoint()
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

            guard kind != .unsupported else {
                throw SkillContentSnapshotError.unsupportedEntry(path: relativePath)
            }
            if SkillContentExclusions.contains(normalizedName, isDirectory: kind == .directory) {
                continue
            }
            guard components.count <= limits.maximumPathDepth else {
                throw SkillContentSnapshotError.pathDepthLimitExceeded(
                    path: relativePath,
                    limit: limits.maximumPathDepth
                )
            }

            if kind == .directory {
                guard directories.count < limits.maximumDirectoryCount else {
                    throw SkillContentSnapshotError.directoryCountLimitExceeded(
                        limit: limits.maximumDirectoryCount
                    )
                }
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
