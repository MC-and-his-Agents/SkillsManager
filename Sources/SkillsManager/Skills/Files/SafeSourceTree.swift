import Darwin
import Foundation

/// Keeps source traversal anchored to the directory selected by the user.
nonisolated final class SafeSourceTree: @unchecked Sendable {
    struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
        let modificationSeconds: time_t
        let modificationNanoseconds: Int
        let statusChangeSeconds: time_t
        let statusChangeNanoseconds: Int

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            generation = metadata.st_gen
            modificationSeconds = metadata.st_mtimespec.tv_sec
            modificationNanoseconds = metadata.st_mtimespec.tv_nsec
            statusChangeSeconds = metadata.st_ctimespec.tv_sec
            statusChangeNanoseconds = metadata.st_ctimespec.tv_nsec
        }
    }

    struct DirectoryStep: Sendable {
        let name: String
        let identity: Identity
    }

    struct DirectoryRecord: Sendable {
        let steps: [DirectoryStep]
        let relativePath: String
    }

    private let rootDescriptor: Int32
    private let rootIdentity: Identity

    init(rootURL: URL) throws {
        var pathMetadata = stat()
        guard Darwin.lstat(rootURL.path, &pathMetadata) == 0,
              SkillContentFileEnumerator.kind(of: pathMetadata) == .directory else {
            throw SkillContentSnapshotError.rootIsNotDirectory(path: rootURL.path)
        }
        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: rootURL.path, code: errno)
        }
        var openedMetadata = stat()
        guard Darwin.fstat(descriptor, &openedMetadata) == 0,
              Identity(openedMetadata) == Identity(pathMetadata) else {
            let code = errno
            Darwin.close(descriptor)
            throw SkillContentSnapshotError.fileSystemFailure(path: rootURL.path, code: code)
        }
        rootDescriptor = descriptor
        rootIdentity = Identity(openedMetadata)
    }

    init(directoryDescriptor: Int32, displayPath: String) throws {
        let descriptor = Darwin.fcntl(directoryDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: code)
        }
        guard SkillContentFileEnumerator.kind(of: metadata) == .directory else {
            Darwin.close(descriptor)
            throw SkillContentSnapshotError.rootIsNotDirectory(path: displayPath)
        }
        rootDescriptor = descriptor
        rootIdentity = Identity(metadata)
    }

    deinit {
        Darwin.close(rootDescriptor)
    }

    func duplicateRoot() throws -> Int32 {
        var metadata = stat()
        guard Darwin.fstat(rootDescriptor, &metadata) == 0,
              Identity(metadata) == rootIdentity else {
            throw SkillContentSnapshotError.fileChanged(path: ".")
        }
        let descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: ".", code: errno)
        }
        return descriptor
    }

    func openFile(_ file: SkillContentFileEnumerator.DiscoveredFile) throws -> Int32 {
        let parentDescriptor = try openDirectoryPath(
            file.directorySteps,
            displayPath: file.relativePath
        )
        defer { Darwin.close(parentDescriptor) }
        let descriptor = Darwin.openat(
            parentDescriptor,
            file.fileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: file.relativePath, code: errno)
        }
        return descriptor
    }

    func verifyDirectories(
        _ directories: [DirectoryRecord],
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        let root = try duplicateRoot()
        Darwin.close(root)
        for directory in directories {
            try checkpoint()
            let descriptor = try openDirectoryPath(
                directory.steps,
                displayPath: directory.relativePath
            )
            Darwin.close(descriptor)
        }
    }

    private func openDirectoryPath(
        _ steps: [DirectoryStep],
        displayPath: String
    ) throws -> Int32 {
        var descriptor = try duplicateRoot()
        for step in steps {
            do {
                let next = try Self.openDirectory(
                    named: step.name,
                    in: descriptor,
                    expectedIdentity: step.identity,
                    displayPath: displayPath
                )
                Darwin.close(descriptor)
                descriptor = next
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    static func openDirectory(
        named name: String,
        in parentDescriptor: Int32,
        expectedIdentity: Identity,
        displayPath: String
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              Identity(metadata) == expectedIdentity else {
            Darwin.close(descriptor)
            throw SkillContentSnapshotError.fileChanged(path: displayPath)
        }
        return descriptor
    }

    static func names(in descriptor: Int32, displayPath: String) throws -> [String] {
        let streamDescriptor = Darwin.dup(descriptor)
        guard streamDescriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        guard let directory = Darwin.fdopendir(streamDescriptor) else {
            let code = errno
            Darwin.close(streamDescriptor)
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: code)
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        Darwin.rewinddir(directory)
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = Self.name(of: entry)
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        return names
    }

    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }
}

extension SkillContentSnapshot {
    nonisolated func copyFiles(
        to destinationRoot: URL,
        limits: SkillContentLimits = .default,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws {
        try checkpoint()
        let rootDescriptor = Darwin.open(
            destinationRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: destinationRoot.path, code: errno)
        }
        defer { Darwin.close(rootDescriptor) }

        try copyFiles(
            toDirectoryDescriptor: rootDescriptor,
            limits: limits,
            checkpoint: checkpoint
        )
    }

    nonisolated func copyFiles(
        toDirectoryDescriptor rootDescriptor: Int32,
        limits: SkillContentLimits = .default,
        checkpoint: SkillCancellationCheckpoint = {},
        failureCleanupAdmission: SkillCancellationCheckpoint? = nil
    ) throws {
        var destinationMetadata = stat()
        guard Darwin.fstat(rootDescriptor, &destinationMetadata) == 0,
              SkillContentFileEnumerator.kind(of: destinationMetadata) == .directory else {
            throw SkillContentSnapshotError.rootIsNotDirectory(path: "destination")
        }

        do {
            try sourceTree.verifyDirectories(sourceDirectories, checkpoint: checkpoint)
            try Self.createDestinationDirectories(
                sourceDirectories,
                rootDescriptor: rootDescriptor,
                checkpoint: checkpoint
            )
            var totalByteCount = UInt64.zero
            for file in discoveredFiles {
                try checkpoint()
                try Self.copyFile(
                    file,
                    sourceTree: sourceTree,
                    toRootDescriptor: rootDescriptor,
                    limits: limits,
                    totalByteCount: &totalByteCount,
                    checkpoint: checkpoint,
                    failureCleanupAdmission: failureCleanupAdmission
                )
            }
            try sourceTree.verifyDirectories(sourceDirectories, checkpoint: checkpoint)
        } catch let cleanupRequired as SSOTPartialCopyCleanupRequired {
            throw cleanupRequired
        } catch {
            guard failureCleanupAdmission != nil else { throw error }
            throw SSOTPartialCopyCleanupRequired(operationReason: error.localizedDescription)
        }
    }

    private nonisolated static func createDestinationDirectories(
        _ directories: [SafeSourceTree.DirectoryRecord],
        rootDescriptor: Int32,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        for directory in directories {
            try checkpoint()
            let components = directory.relativePath
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
                throw SkillContentSnapshotError.fileChanged(path: directory.relativePath)
            }
            let descriptor = try openDestinationDirectory(
                components,
                rootDescriptor: rootDescriptor,
                displayPath: directory.relativePath
            )
            Darwin.close(descriptor)
        }
    }

    private nonisolated static func copyFile(
        _ file: SkillContentFileEnumerator.DiscoveredFile,
        sourceTree: SafeSourceTree,
        toRootDescriptor rootDescriptor: Int32,
        limits: SkillContentLimits,
        totalByteCount: inout UInt64,
        checkpoint: SkillCancellationCheckpoint,
        failureCleanupAdmission: SkillCancellationCheckpoint?
    ) throws {
        guard file.byteCount <= limits.maximumFileByteCount else {
            throw SkillContentSnapshotError.fileByteLimitExceeded(
                path: file.relativePath,
                limit: limits.maximumFileByteCount,
                actual: file.byteCount
            )
        }
        let sourceDescriptor = try openValidatedSource(file, sourceTree: sourceTree)
        defer { Darwin.close(sourceDescriptor) }

        try withDestinationParent(for: file.relativePath, rootDescriptor: rootDescriptor) {
            try copyBytes(
                from: sourceDescriptor,
                file: file,
                toParent: $0,
                destinationRoot: rootDescriptor,
                name: $1,
                limits: limits,
                totalByteCount: &totalByteCount,
                checkpoint: checkpoint,
                failureCleanupAdmission: failureCleanupAdmission
            )
        }
        try verifyFinalSource(sourceDescriptor, file: file)
    }

}
