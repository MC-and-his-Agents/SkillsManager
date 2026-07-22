import Darwin
import Foundation

nonisolated final class ManagedDirectoryHandle {
    let url: URL
    let identity: ManagedItemIdentity
    let descriptor: Int32

    init(url: URL, identity: ManagedItemIdentity, descriptor: Int32) {
        self.url = url
        self.identity = identity
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }
}

nonisolated extension ManagedPathGuard {
    private struct DirectoryMutationToken: Equatable {
        let modificationSeconds: time_t
        let modificationNanoseconds: Int
        let statusChangeSeconds: time_t
        let statusChangeNanoseconds: Int

        init(_ status: stat) {
            modificationSeconds = status.st_mtimespec.tv_sec
            modificationNanoseconds = status.st_mtimespec.tv_nsec
            statusChangeSeconds = status.st_ctimespec.tv_sec
            statusChangeNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    func promoteStagedItemIfAbsent(
        at stagedURL: URL,
        to targetURL: URL,
        expectedStaged: ManagedItemIdentity,
        validateStaged: (Int32) throws -> Void
    ) throws {
        try promoteStagedItemIfAbsent(
            at: stagedURL,
            to: targetURL,
            expectedStaged: expectedStaged,
            validateStaged: validateStaged,
            validateCommitted: validateStaged
        )
    }

    func replaceStagedItem(
        at stagedURL: URL,
        to targetURL: URL,
        expectedStaged: ManagedItemIdentity,
        expectedTarget: ManagedItemIdentity,
        validateStaged: (Int32) throws -> Void
    ) throws -> ManagedPromotionResult {
        try replaceStagedItem(
            at: stagedURL,
            to: targetURL,
            expectedStaged: expectedStaged,
            expectedTarget: expectedTarget,
            validateStaged: validateStaged,
            validateCommitted: validateStaged
        )
    }

    func createDirectory(
        at url: URL,
        afterTemporaryCreate: (URL) throws -> Void = { _ in },
        afterCreate: () throws -> Void = {},
        afterOpen: () throws -> Void = {},
        admitFailureCleanup: () throws -> Void = {}
    ) throws -> ManagedDirectoryHandle {
        try verifyRootIdentity()
        let targetName = try managedName(for: url).value
        let unpublished = try createUnpublishedDirectory(for: url)
        var cleanupURL = unpublished.url
        var descriptor: Int32?

        do {
            try afterTemporaryCreate(unpublished.url)
            let openedDescriptor = try openVerifiedDirectory(
                named: unpublished.name,
                expectedIdentity: unpublished.identity
            )
            descriptor = openedDescriptor
            try verifyRootIdentity()
            guard Darwin.renameatx_np(
                rootDescriptor,
                unpublished.name,
                rootDescriptor,
                targetName,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw ManagedPathError.posix(operation: "publish managed directory", code: errno)
            }
            cleanupURL = url
            try afterCreate()
            try afterOpen()
            guard try itemIdentity(at: url) == unpublished.identity else {
                throw ManagedPathError.itemChanged
            }
            try verifyRootIdentity()
            descriptor = nil
            return ManagedDirectoryHandle(
                url: url,
                identity: unpublished.identity,
                descriptor: openedDescriptor
            )
        } catch let operationError {
            if let descriptor { Darwin.close(descriptor) }
            try throwCreationFailure(
                operationError,
                at: cleanupURL,
                expectedIdentity: unpublished.identity,
                admitFailureCleanup: admitFailureCleanup
            )
        }
    }

    private func createUnpublishedDirectory(
        for targetURL: URL
    ) throws -> (name: String, url: URL, identity: ManagedItemIdentity) {
        while true {
            let name = ".skillsmanager-tmp-create-\(UUID().uuidString.lowercased())"
            let temporaryURL = targetURL.deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: true)
            guard Darwin.mkdirat(rootDescriptor, name, S_IRWXU) == 0 else {
                if errno == EEXIST { continue }
                throw ManagedPathError.posix(operation: "create managed directory", code: errno)
            }

            var metadata = stat()
            guard Darwin.fstatat(
                rootDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw creationFailureWithoutIdentity(
                    ManagedPathError.posix(operation: "inspect managed directory", code: errno),
                    at: temporaryURL
                )
            }
            guard ManagedPathGuard.fileType(of: metadata) == S_IFDIR else {
                throw creationFailureWithoutIdentity(
                    ManagedPathError.itemChanged,
                    at: temporaryURL
                )
            }
            return (name, temporaryURL, ManagedItemIdentity(metadata))
        }
    }

    private func openVerifiedDirectory(
        named name: String,
        expectedIdentity: ManagedItemIdentity
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            rootDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ManagedPathError.posix(operation: "open managed directory", code: errno)
        }
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  ManagedPathGuard.fileType(of: metadata) == S_IFDIR,
                  ManagedItemIdentity(metadata) == expectedIdentity,
                  try identity(of: name, in: rootDescriptor) == expectedIdentity else {
                throw ManagedPathError.itemChanged
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func creationFailureWithoutIdentity(
        _ error: Error,
        at url: URL
    ) -> SafeSkillStagingFailure {
        SafeSkillStagingFailure(
            originalReason: error.localizedDescription,
            cleanupDebts: [SafeSkillCleanupDebt(
                url: url,
                reason: "The staging directory identity could not be established; inspect it before cleanup."
            )]
        )
    }

    private func throwCreationFailure(
        _ operationError: Error,
        at url: URL,
        expectedIdentity: ManagedItemIdentity?,
        admitFailureCleanup: () throws -> Void
    ) throws -> Never {
        guard let expectedIdentity else {
            throw creationFailureWithoutIdentity(operationError, at: url)
        }
        try admitFailureCleanup()
        do {
            try removeItem(at: url, expectedIdentity: expectedIdentity)
        } catch let cleanupError {
            throw SafeSkillStagingFailure(
                originalReason: operationError.localizedDescription,
                cleanupDebts: [SafeSkillCleanupDebt(
                    url: url,
                    reason: cleanupError.localizedDescription
                )]
            )
        }
        throw operationError
    }

    func withItemDescriptor<T>(
        at url: URL,
        expectedIdentity: ManagedItemIdentity,
        _ body: (Int32) throws -> T
    ) throws -> T {
        try verifyRootIdentity()
        let name = try managedName(for: url).value
        let descriptor = Darwin.openat(
            rootDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ManagedPathError.posix(operation: "open managed directory", code: errno)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              ManagedItemIdentity(metadata) == expectedIdentity else {
            throw ManagedPathError.itemChanged
        }
        let result = try body(descriptor)
        guard try itemIdentity(at: url) == expectedIdentity else {
            throw ManagedPathError.itemChanged
        }
        return result
    }

    func managedItemNames() throws -> [String] {
        for _ in 0..<3 {
            try verifyRootIdentity()
            let before = try rootMutationToken()
            let names = try directoryNamesOnce()
            let after = try rootMutationToken()
            try verifyRootIdentity()
            if before == after { return names }
        }
        throw ManagedPathError.itemChanged
    }

    private func directoryNamesOnce() throws -> [String] {
        let duplicate = Darwin.fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw ManagedPathError.posix(operation: "duplicate managed root", code: errno)
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw ManagedPathError.posix(operation: "enumerate managed root", code: code)
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        Darwin.rewinddir(directory)
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = Self.directoryEntryName(entry)
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else {
            throw ManagedPathError.posix(operation: "enumerate managed root", code: errno)
        }
        return names
    }

    private func rootMutationToken() throws -> DirectoryMutationToken {
        var status = stat()
        guard Darwin.fstat(rootDescriptor, &status) == 0 else {
            throw ManagedPathError.posix(operation: "inspect managed root", code: errno)
        }
        return DirectoryMutationToken(status)
    }

    func verifyUniqueEquivalentSibling(named targetName: String) throws {
        try hooks.beforeEquivalentSiblingCheck()
        let targetKey = SkillContentPath.collisionKey(for: targetName)
        let matches = try managedItemNames().filter {
            !$0.hasPrefix(".skillsmanager-tmp-")
                && SkillContentPath.collisionKey(for: $0) == targetKey
        }
        guard matches == [targetName] else { throw ManagedPathError.itemChanged }
    }

    func rollbackNoReplace(
        names: PromotionNames,
        expectedStaged: ManagedItemIdentity
    ) -> Bool {
        guard (try? identity(of: names.target, in: rootDescriptor)) == expectedStaged,
              (try? identityIfPresent(of: names.staged, in: rootDescriptor)) == nil else {
            return false
        }
        return Darwin.renameatx_np(
            rootDescriptor,
            names.target,
            rootDescriptor,
            names.staged,
            UInt32(RENAME_EXCL)
        ) == 0 && (try? identity(of: names.staged, in: rootDescriptor)) == expectedStaged
    }

    func rollbackReplace(
        names: PromotionNames,
        expectedStaged: ManagedItemIdentity,
        expectedTarget: ManagedItemIdentity
    ) -> Bool {
        guard (try? identity(of: names.target, in: rootDescriptor)) == expectedStaged,
              (try? identity(of: names.staged, in: rootDescriptor)) == expectedTarget else {
            return false
        }
        guard swap(names) == 0 else { return false }
        return (try? identity(of: names.staged, in: rootDescriptor)) == expectedStaged
            && (try? identity(of: names.target, in: rootDescriptor)) == expectedTarget
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }
}
