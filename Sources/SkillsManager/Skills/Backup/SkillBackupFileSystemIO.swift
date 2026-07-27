import Darwin
import CryptoKit
import Foundation

nonisolated extension SkillBackupFileSystem {
    func stageBackupContents(
        snapshot: SkillContentSnapshot,
        stagingDescriptor: Int32,
        finalURL: URL,
        manifestBytes: Data,
        expectedFingerprint: SkillContentFingerprint
    ) throws {
        let filesDescriptor = try createDirectory(
            named: Self.filesName,
            in: stagingDescriptor
        )
        defer { Darwin.close(filesDescriptor) }
        try snapshot.copyFiles(
            toDirectoryDescriptor: filesDescriptor,
            limits: limits,
            checkpoint: { try self.validateAuthority() },
            failureCleanupAdmission: { try self.validateAuthority() }
        )
        let copied = try SkillContentSnapshot.capture(
            directoryDescriptor: filesDescriptor,
            displayPath: finalURL.appendingPathComponent(Self.filesName).path,
            limits: limits,
            checkpoint: { try self.validateAuthority() }
        )
        guard copied.fingerprintDigest == expectedFingerprint.digest else {
            throw SkillBackupFileSystemError.contentChanged
        }
        try synchronize(snapshot: copied)
        try writeFile(
            named: Self.manifestName,
            bytes: manifestBytes,
            in: stagingDescriptor
        )
        try SSOTDurability.syncDirectory(stagingDescriptor)
    }

    func validatePublishedDirectory(
        _ descriptor: Int32,
        expectedManifestDigest: Data,
        expectedFingerprint: SkillContentFingerprint
    ) throws {
        let manifest = try readFile(named: Self.manifestName, in: descriptor)
        guard Data(SHA256.hash(data: manifest)) == expectedManifestDigest else {
            throw SkillBackupFileSystemError.manifestChanged
        }
        let filesDescriptor = try openDirectory(named: Self.filesName, in: descriptor)
        defer { Darwin.close(filesDescriptor) }
        let snapshot = try SkillContentSnapshot.capture(
            directoryDescriptor: filesDescriptor,
            displayPath: "published backup",
            limits: limits
        )
        guard snapshot.fingerprintDigest == expectedFingerprint.digest else {
            throw SkillBackupFileSystemError.contentChanged
        }
    }

    func createDirectory(named name: String, in parent: Int32) throws -> Int32 {
        guard Darwin.mkdirat(parent, name, S_IRWXU) == 0 else {
            throw posix("create backup directory")
        }
        return try openDirectory(named: name, in: parent)
    }

    func openDirectory(named name: String, in parent: Int32) throws -> Int32 {
        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posix("open backup directory") }
        return descriptor
    }

    func writeFile(named name: String, bytes: Data, in parent: Int32) throws {
        let descriptor = Darwin.openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posix("create backup manifest") }
        defer { Darwin.close(descriptor) }
        try bytes.withUnsafeBytes { rawBuffer in
            var written = 0
            while written < rawBuffer.count {
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw SkillBackupFileSystemError.manifestChanged
                }
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard result > 0 else { throw posix("write backup manifest") }
                written += result
            }
        }
        try SSOTDurability.syncFile(descriptor)
    }

    func readFile(named name: String, in parent: Int32) throws -> Data {
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix("open backup manifest") }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              metadata.st_size <= 8 * 1_024 * 1_024 else {
            throw SkillBackupFileSystemError.manifestChanged
        }
        var data = Data(count: Int(metadata.st_size))
        try data.withUnsafeMutableBytes { rawBuffer in
            var readCount = 0
            while readCount < rawBuffer.count {
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw SkillBackupFileSystemError.manifestChanged
                }
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: readCount),
                    rawBuffer.count - readCount
                )
                guard result > 0 else { throw posix("read backup manifest") }
                readCount += result
            }
        }
        return data
    }

    func synchronize(snapshot: SkillContentSnapshot) throws {
        for file in snapshot.discoveredFiles {
            let parent = try openDirectory(
                steps: file.directorySteps,
                in: snapshot.sourceTree
            )
            let descriptor = Darwin.openat(
                parent,
                file.fileName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            if descriptor < 0 {
                Darwin.close(parent)
                throw posix("open backup file for sync")
            }
            do {
                try SSOTDurability.syncFile(descriptor)
                Darwin.close(descriptor)
                Darwin.close(parent)
            } catch {
                Darwin.close(descriptor)
                Darwin.close(parent)
                throw error
            }
        }
        for directory in snapshot.sourceDirectories.reversed() {
            let descriptor = try openDirectory(
                steps: directory.steps,
                in: snapshot.sourceTree
            )
            do {
                try SSOTDurability.syncDirectory(descriptor)
                Darwin.close(descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        let root = try snapshot.sourceTree.duplicateRoot()
        defer { Darwin.close(root) }
        try SSOTDurability.syncDirectory(root)
    }

    func openDirectory(
        steps: [SafeSourceTree.DirectoryStep],
        in tree: SafeSourceTree
    ) throws -> Int32 {
        var descriptor = try tree.duplicateRoot()
        for step in steps {
            do {
                let child = try SafeSourceTree.openDirectory(
                    named: step.name,
                    in: descriptor,
                    expectedIdentity: step.identity,
                    displayPath: step.name
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

    func posix(_ operation: String) -> SkillBackupFileSystemError {
        .posix(operation: operation, code: errno)
    }
}
