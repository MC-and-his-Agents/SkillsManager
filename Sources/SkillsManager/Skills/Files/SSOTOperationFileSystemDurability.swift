import Darwin
import Foundation

extension SSOTOperationFileSystem {
    nonisolated func synchronize(
        snapshot: SkillContentSnapshot,
        checkpoint: SkillCancellationCheckpoint = {}
    ) throws {
        for file in snapshot.discoveredFiles {
            try checkpoint()
            do {
                let descriptor = try openReadOnlyFile(file, in: snapshot.sourceTree)
                defer { Darwin.close(descriptor) }
                try SSOTDurability.syncFile(descriptor)
            }
        }
        for directory in snapshot.sourceDirectories.reversed() {
            try checkpoint()
            do {
                let descriptor = try openDirectory(
                    steps: directory.steps,
                    in: snapshot.sourceTree,
                    displayPath: directory.relativePath
                )
                defer { Darwin.close(descriptor) }
                try SSOTDurability.syncDirectory(descriptor)
            }
        }
        try checkpoint()
        let rootDescriptor = try snapshot.sourceTree.duplicateRoot()
        defer { Darwin.close(rootDescriptor) }
        try SSOTDurability.syncDirectory(rootDescriptor)
    }

    private nonisolated func openReadOnlyFile(
        _ file: SkillContentFileEnumerator.DiscoveredFile,
        in tree: SafeSourceTree
    ) throws -> Int32 {
        let parent = try openDirectory(
            steps: file.directorySteps,
            in: tree,
            displayPath: file.relativePath
        )
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(parent, file.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SSOTOperationFileSystemError.posix(
                operation: "open staged Skill file for sync",
                code: errno
            )
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_dev == file.device,
              metadata.st_ino == file.inode,
              metadata.st_gen == file.generation,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) == file.byteCount else {
            Darwin.close(descriptor)
            throw SSOTOperationFileSystemError.itemChanged
        }
        return descriptor
    }

    private nonisolated func openDirectory(
        steps: [SafeSourceTree.DirectoryStep],
        in tree: SafeSourceTree,
        displayPath: String
    ) throws -> Int32 {
        var descriptor = try tree.duplicateRoot()
        for step in steps {
            do {
                let child = try SafeSourceTree.openDirectory(
                    named: step.name,
                    in: descriptor,
                    expectedIdentity: step.identity,
                    displayPath: displayPath
                )
                Darwin.close(descriptor)
                descriptor = child
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        return descriptor
    }
}
