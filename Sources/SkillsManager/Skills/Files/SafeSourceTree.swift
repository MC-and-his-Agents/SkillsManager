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
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws {
        var destinationMetadata = stat()
        guard Darwin.fstat(rootDescriptor, &destinationMetadata) == 0,
              SkillContentFileEnumerator.kind(of: destinationMetadata) == .directory else {
            throw SkillContentSnapshotError.rootIsNotDirectory(path: "destination")
        }

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
                checkpoint: checkpoint
            )
        }
        try sourceTree.verifyDirectories(sourceDirectories, checkpoint: checkpoint)
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
        checkpoint: SkillCancellationCheckpoint
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
                name: $1,
                limits: limits,
                totalByteCount: &totalByteCount,
                checkpoint: checkpoint
            )
        }
        try verifyFinalSource(sourceDescriptor, file: file)
    }

    private nonisolated static func copyBytes(
        from sourceDescriptor: Int32,
        file: SkillContentFileEnumerator.DiscoveredFile,
        toParent parentDescriptor: Int32,
        name: String,
        limits: SkillContentLimits,
        totalByteCount: inout UInt64,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        let destinationDescriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: file.relativePath, code: errno)
        }
        var completed = false
        defer {
            Darwin.close(destinationDescriptor)
            if !completed { Darwin.unlinkat(parentDescriptor, name, 0) }
        }

        var fileByteCount = UInt64.zero
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkpoint()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw SkillContentSnapshotError.fileSystemFailure(path: file.relativePath, code: errno)
            }
            if count == 0 { break }
            try addCopiedBytes(
                UInt64(count),
                file: file,
                fileByteCount: &fileByteCount,
                totalByteCount: &totalByteCount,
                limits: limits
            )
            try writeAll(buffer.prefix(count), to: destinationDescriptor, checkpoint: checkpoint)
        }
        guard fileByteCount == file.byteCount else {
            throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
        }
        guard Darwin.fchmod(destinationDescriptor, file.safePermissions) == 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: file.relativePath, code: errno)
        }
        completed = true
    }

    private nonisolated static func addCopiedBytes(
        _ count: UInt64,
        file: SkillContentFileEnumerator.DiscoveredFile,
        fileByteCount: inout UInt64,
        totalByteCount: inout UInt64,
        limits: SkillContentLimits
    ) throws {
        let (newFileCount, fileOverflow) = fileByteCount.addingReportingOverflow(count)
        guard !fileOverflow, newFileCount <= limits.maximumFileByteCount,
              newFileCount <= file.byteCount else {
            throw SkillContentSnapshotError.fileChanged(path: file.relativePath)
        }
        let (newTotal, totalOverflow) = totalByteCount.addingReportingOverflow(count)
        guard !totalOverflow, newTotal <= limits.maximumTotalByteCount else {
            throw SkillContentSnapshotError.totalByteLimitExceeded(
                limit: limits.maximumTotalByteCount,
                actual: totalOverflow ? UInt64.max : newTotal
            )
        }
        fileByteCount = newFileCount
        totalByteCount = newTotal
    }

    private nonisolated static func writeAll(
        _ bytes: ArraySlice<UInt8>,
        to descriptor: Int32,
        checkpoint: SkillCancellationCheckpoint
    ) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                try checkpoint()
                let count = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SkillContentSnapshotError.fileSystemFailure(path: "destination", code: errno)
                }
                offset += count
            }
        }
    }

    private nonisolated static func withDestinationParent<T>(
        for relativePath: String,
        rootDescriptor: Int32,
        body: (Int32, String) throws -> T
    ) throws -> T {
        var components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let fileName = components.popLast(), !fileName.isEmpty else {
            throw SkillContentSnapshotError.fileChanged(path: relativePath)
        }
        let parentDescriptor = try openDestinationDirectory(
            components,
            rootDescriptor: rootDescriptor,
            displayPath: relativePath
        )
        defer { Darwin.close(parentDescriptor) }

        return try body(parentDescriptor, fileName)
    }

    private nonisolated static func openDestinationDirectory(
        _ components: [String],
        rootDescriptor: Int32,
        displayPath: String
    ) throws -> Int32 {
        var parentDescriptor = Darwin.dup(rootDescriptor)
        guard parentDescriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        for component in components {
            if Darwin.mkdirat(parentDescriptor, component, S_IRWXU) != 0, errno != EEXIST {
                Darwin.close(parentDescriptor)
                throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
            }
            let next = Darwin.openat(
                parentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                let code = errno
                Darwin.close(parentDescriptor)
                throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: code)
            }
            Darwin.close(parentDescriptor)
            parentDescriptor = next
        }
        return parentDescriptor
    }
}
