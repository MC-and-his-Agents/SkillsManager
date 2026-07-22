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
        afterCreate: () throws -> Void = {},
        afterOpen: () throws -> Void = {}
    ) throws -> ManagedDirectoryHandle {
        try verifyRootIdentity()
        let name = try managedName(for: url).value
        guard Darwin.mkdirat(rootDescriptor, name, S_IRWXU) == 0 else {
            throw ManagedPathError.posix(operation: "create managed directory", code: errno)
        }
        do {
            try afterCreate()
        } catch {
            throw creationFailureWithoutIdentity(error, at: url)
        }
        let descriptor = Darwin.openat(
            rootDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw creationFailureWithoutIdentity(
                ManagedPathError.posix(operation: "open managed directory", code: errno),
                at: url
            )
        }
        var identity: ManagedItemIdentity?
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                throw ManagedPathError.posix(operation: "inspect managed directory", code: errno)
            }
            let openedIdentity = ManagedItemIdentity(metadata)
            identity = openedIdentity
            try afterOpen()
            guard ManagedPathGuard.fileType(of: metadata) == S_IFDIR,
                  try itemIdentity(at: url) == openedIdentity else {
                throw ManagedPathError.itemChanged
            }
            try verifyRootIdentity()
            return ManagedDirectoryHandle(url: url, identity: openedIdentity, descriptor: descriptor)
        } catch let operationError {
            Darwin.close(descriptor)
            try throwCreationFailure(
                operationError,
                at: url,
                expectedIdentity: identity
            )
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
        expectedIdentity: ManagedItemIdentity?
    ) throws -> Never {
        guard let expectedIdentity else {
            throw creationFailureWithoutIdentity(operationError, at: url)
        }
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
