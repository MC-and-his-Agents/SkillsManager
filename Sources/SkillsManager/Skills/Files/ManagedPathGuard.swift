import Darwin
import Foundation
nonisolated enum ManagedPathError: LocalizedError, Equatable {
    case invalidRoot(String)
    case rootReplaced
    case targetIsRoot
    case targetIsNotDirectChild
    case itemNotFound
    case itemChanged
    case destinationAlreadyExists
    case unsupportedItemType
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let reason): "Invalid managed root: \(reason)"
        case .rootReplaced: "The managed root was replaced after it was registered."
        case .targetIsRoot: "The managed root itself cannot be used as an item target."
        case .targetIsNotDirectChild: "The target must be a direct child of the managed root."
        case .itemNotFound: "The managed item does not exist."
        case .itemChanged: "The managed item changed during the operation."
        case .destinationAlreadyExists: "The destination already exists."
        case .unsupportedItemType: "The managed item has an unsupported file type."
        case .posix(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}
nonisolated struct ManagedItemIdentity: Equatable, Sendable {
    fileprivate let device: UInt64
    fileprivate let inode: UInt64
    fileprivate let fileType: UInt32
    fileprivate let generation: UInt64
    fileprivate init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        fileType = UInt32(value.st_mode & mode_t(S_IFMT))
        generation = UInt64(value.st_gen)
    }
}
nonisolated enum ManagedPromotionResult: Equatable {
    case committed
    case committedWithCleanupDebt(URL, ManagedPathError)
}
nonisolated struct ManagedPathGuardTestHooks {
    var beforeNoReplaceCommit: () throws -> Void = {}
    var beforeReplaceCommit: () throws -> Void = {}
    var beforeRollback: () throws -> Void = {}
    var beforeCleanup: () throws -> Void = {}
    var beforeQuarantineMove: (String) throws -> Void = { _ in }
}
nonisolated final class ManagedPathGuard {
    private typealias FileIdentity = ManagedItemIdentity
    private struct ManagedName {
        let value: String
    }

    private struct PromotionNames {
        let staged: String
        let target: String
    }
    private let rootPath: String
    private let canonicalRootPath: String
    private let rootIdentity: FileIdentity
    private let rootDescriptor: Int32
    private let hooks: ManagedPathGuardTestHooks
    init(rootURL: URL, hooks: ManagedPathGuardTestHooks = .init()) throws {
        guard rootURL.isFileURL else {
            throw ManagedPathError.invalidRoot("not a file URL")
        }
        let standardizedRoot = rootURL.standardizedFileURL
        let path = standardizedRoot.path
        var pathStatus = stat()
        guard Darwin.lstat(path, &pathStatus) == 0 else {
            throw ManagedPathError.invalidRoot(Self.errorMessage(errno))
        }
        guard Self.fileType(of: pathStatus) == S_IFDIR else {
            throw ManagedPathError.invalidRoot("not a directory or is a symbolic link")
        }
        let canonicalPath = try Self.canonicalPath(for: path)
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ManagedPathError.invalidRoot(Self.errorMessage(errno))
        }
        do {
            var descriptorStatus = stat()
            guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
                throw ManagedPathError.posix(operation: "fstat managed root", code: errno)
            }
            guard Self.fileType(of: descriptorStatus) == S_IFDIR,
                  FileIdentity(pathStatus) == FileIdentity(descriptorStatus) else {
                throw ManagedPathError.invalidRoot("changed while being registered")
            }
            rootPath = path
            canonicalRootPath = canonicalPath
            rootIdentity = FileIdentity(descriptorStatus)
            rootDescriptor = descriptor
            self.hooks = hooks
            try verifyRootIdentity()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
    deinit {
        Darwin.close(rootDescriptor)
    }
    func itemExists(at targetURL: URL) throws -> Bool {
        try verifyRootIdentity()
        let name = try managedName(for: targetURL)
        try verifyRootIdentity()
        var itemStatus = stat()
        if Darwin.fstatat(rootDescriptor, name.value, &itemStatus, AT_SYMLINK_NOFOLLOW) == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw ManagedPathError.posix(operation: "lstat managed item", code: errno)
    }
    func removeItem(at targetURL: URL) throws {
        guard let expected = try itemIdentity(at: targetURL) else {
            throw ManagedPathError.itemNotFound
        }
        try removeItem(at: targetURL, expectedIdentity: expected)
    }
    func removeItem(at targetURL: URL, expectedIdentity: ManagedItemIdentity) throws {
        try verifyRootIdentity()
        let name = try managedName(for: targetURL)
        try verifyRootIdentity()
        try removeNamedItem(name.value, from: rootDescriptor, expectedIdentity: expectedIdentity)
        try verifyRootIdentity()
    }
    func itemIdentity(at targetURL: URL) throws -> ManagedItemIdentity? {
        try verifyRootIdentity()
        let name = try managedName(for: targetURL)
        try verifyRootIdentity()
        return try identityIfPresent(of: name.value, in: rootDescriptor)
    }
    func promoteStagedItemIfAbsent(at stagedURL: URL, to targetURL: URL) throws {
        let names = try promotionNames(stagedURL: stagedURL, targetURL: targetURL)
        let stagedIdentity = try identity(of: names.staged, in: rootDescriptor)
        try hooks.beforeNoReplaceCommit()
        try verifyRootIdentity()
        guard Darwin.renameatx_np(
            rootDescriptor,
            names.staged,
            rootDescriptor,
            names.target,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST {
                throw ManagedPathError.destinationAlreadyExists
            }
            throw ManagedPathError.posix(operation: "promote staged item", code: errno)
        }
        guard try identity(of: names.target, in: rootDescriptor) == stagedIdentity else {
            throw ManagedPathError.itemChanged
        }
        try verifyRootIdentity()
    }
    func replaceStagedItem(
        at stagedURL: URL,
        to targetURL: URL,
        expectedTarget: ManagedItemIdentity
    ) throws -> ManagedPromotionResult {
        let names = try promotionNames(stagedURL: stagedURL, targetURL: targetURL)
        let stagedIdentity = try identity(of: names.staged, in: rootDescriptor)
        try hooks.beforeReplaceCommit()
        guard try identityIfPresent(of: names.target, in: rootDescriptor) == expectedTarget else {
            throw ManagedPathError.itemChanged
        }
        try verifyRootIdentity()
        guard swap(names) == 0 else {
            throw ManagedPathError.posix(operation: "swap staged and existing items", code: errno)
        }
        guard try identityIfPresent(of: names.target, in: rootDescriptor) == stagedIdentity,
              try identityIfPresent(of: names.staged, in: rootDescriptor) == expectedTarget else {
            return try rollbackUnexpectedCommit(names: names, stagedIdentity: stagedIdentity)
        }
        return try cleanReplacedItem(
            names: names,
            stagedIdentity: stagedIdentity,
            expectedTarget: expectedTarget
        )
    }
    private func managedName(for targetURL: URL) throws -> ManagedName {
        guard targetURL.isFileURL else {
            throw ManagedPathError.targetIsNotDirectChild
        }
        let rawPath = targetURL.path
        if rawPath == rootPath {
            throw ManagedPathError.targetIsRoot
        }
        let components = (rawPath as NSString).pathComponents
        guard !components.contains("."), !components.contains("..") else {
            throw ManagedPathError.targetIsNotDirectChild
        }
        let target = targetURL.standardizedFileURL
        guard target.deletingLastPathComponent().path == rootPath,
              target.path != rootPath else {
            throw ManagedPathError.targetIsNotDirectChild
        }
        let name = target.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw ManagedPathError.targetIsNotDirectChild
        }
        guard try Self.canonicalPath(for: target.deletingLastPathComponent().path) == canonicalRootPath else {
            throw ManagedPathError.targetIsNotDirectChild
        }
        return ManagedName(value: name)
    }
    private func verifyRootIdentity() throws {
        var pathStatus = stat()
        guard Darwin.lstat(rootPath, &pathStatus) == 0,
              Self.fileType(of: pathStatus) == S_IFDIR,
              FileIdentity(pathStatus) == rootIdentity else {
            throw ManagedPathError.rootReplaced
        }
        guard try Self.canonicalPath(for: rootPath) == canonicalRootPath else {
            throw ManagedPathError.rootReplaced
        }
        var descriptorStatus = stat()
        guard Darwin.fstat(rootDescriptor, &descriptorStatus) == 0,
              Self.fileType(of: descriptorStatus) == S_IFDIR,
              FileIdentity(descriptorStatus) == rootIdentity else {
            throw ManagedPathError.rootReplaced
        }
    }
    private func promotionNames(stagedURL: URL, targetURL: URL) throws -> PromotionNames {
        try verifyRootIdentity()
        let staged = try managedName(for: stagedURL).value
        let target = try managedName(for: targetURL).value
        guard staged != target else {
            throw ManagedPathError.itemChanged
        }
        try verifyRootIdentity()
        return PromotionNames(staged: staged, target: target)
    }
    private func swap(_ names: PromotionNames) -> Int32 {
        Darwin.renameatx_np(
            rootDescriptor,
            names.staged,
            rootDescriptor,
            names.target,
            UInt32(RENAME_SWAP)
        )
    }
    private func cleanReplacedItem(
        names: PromotionNames,
        stagedIdentity: ManagedItemIdentity,
        expectedTarget: ManagedItemIdentity
    ) throws -> ManagedPromotionResult {
        do { try hooks.beforeCleanup() } catch let cleanupError as ManagedPathError {
            return try rollbackAfterCleanupFailure(
                names: names,
                stagedIdentity: stagedIdentity,
                expectedTarget: expectedTarget,
                cleanupError: cleanupError
            )
        }
        let oldStatus = try status(of: names.staged, in: rootDescriptor)
        guard FileIdentity(oldStatus) == expectedTarget else {
            return .committedWithCleanupDebt(cleanupURL(for: names), .itemChanged)
        }
        do {
            try removeQuarantinedItem(names.staged, status: oldStatus, in: rootDescriptor)
            try verifyRootIdentity()
            return .committed
        } catch let cleanupError as ManagedPathError {
            return .committedWithCleanupDebt(cleanupURL(for: names), cleanupError)
        }
    }

    private func rollbackAfterCleanupFailure(
        names: PromotionNames,
        stagedIdentity: ManagedItemIdentity,
        expectedTarget: ManagedItemIdentity,
        cleanupError: ManagedPathError
    ) throws -> ManagedPromotionResult {
        let targetIsCommitted = try identityIfPresent(of: names.target, in: rootDescriptor) == stagedIdentity
        guard targetIsCommitted,
              try identityIfPresent(of: names.staged, in: rootDescriptor) == expectedTarget else {
            return .committedWithCleanupDebt(cleanupURL(for: names), cleanupError)
        }
        do { try hooks.beforeRollback() } catch {
            return .committedWithCleanupDebt(cleanupURL(for: names), cleanupError)
        }
        guard swap(names) == 0 else {
            return .committedWithCleanupDebt(cleanupURL(for: names), cleanupError)
        }
        throw cleanupError
    }

    private func rollbackUnexpectedCommit(
        names: PromotionNames,
        stagedIdentity: ManagedItemIdentity
    ) throws -> ManagedPromotionResult {
        guard try identityIfPresent(of: names.target, in: rootDescriptor) == stagedIdentity,
              try identityIfPresent(of: names.staged, in: rootDescriptor) != nil else {
            return .committedWithCleanupDebt(cleanupURL(for: names), .itemChanged)
        }
        do {
            try hooks.beforeRollback()
            guard swap(names) == 0 else {
                return .committedWithCleanupDebt(cleanupURL(for: names), .itemChanged)
            }
        } catch {
            return .committedWithCleanupDebt(cleanupURL(for: names), .itemChanged)
        }
        throw ManagedPathError.itemChanged
    }

    private func cleanupURL(for names: PromotionNames) -> URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent(names.staged)
    }

    private func identity(of name: String, in parentDescriptor: Int32) throws -> FileIdentity {
        var itemStatus = stat()
        guard Darwin.fstatat(parentDescriptor, name, &itemStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                throw ManagedPathError.itemNotFound
            }
            throw ManagedPathError.posix(operation: "lstat managed item", code: errno)
        }
        return FileIdentity(itemStatus)
    }

    private func identityIfPresent(
        of name: String,
        in parentDescriptor: Int32
    ) throws -> FileIdentity? {
        do {
            return try identity(of: name, in: parentDescriptor)
        } catch ManagedPathError.itemNotFound {
            return nil
        }
    }

    private func removeNamedItem(
        _ name: String, from parentDescriptor: Int32, expectedIdentity: FileIdentity? = nil
    ) throws {
        try verifyRootIdentity()
        let initialStatus = try status(of: name, in: parentDescriptor)
        let initialIdentity = FileIdentity(initialStatus)
        guard expectedIdentity == nil || expectedIdentity == initialIdentity else { throw ManagedPathError.itemChanged }
        try hooks.beforeQuarantineMove(name)
        try verifyRootIdentity()
        let quarantine = try moveToQuarantine(name, in: parentDescriptor)
        let movedStatus = try status(of: quarantine, in: parentDescriptor)
        guard FileIdentity(movedStatus) == initialIdentity else {
            restoreQuarantined(quarantine, to: name, in: parentDescriptor)
            throw ManagedPathError.itemChanged
        }
        try removeQuarantinedItem(
            quarantine,
            status: movedStatus,
            in: parentDescriptor
        )
    }

    private func removeQuarantinedItem(
        _ name: String,
        status: stat,
        in parentDescriptor: Int32
    ) throws {
        let expectedIdentity = FileIdentity(status)
        if Self.fileType(of: status) == S_IFDIR {
            let childDescriptor = Darwin.openat(
                parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard childDescriptor >= 0 else {
                throw ManagedPathError.posix(operation: "open directory for removal", code: errno)
            }
            defer { Darwin.close(childDescriptor) }

            var openedStatus = stat()
            guard Darwin.fstat(childDescriptor, &openedStatus) == 0,
                  FileIdentity(openedStatus) == expectedIdentity else {
                throw ManagedPathError.itemChanged
            }
            try removeDirectoryContents(descriptor: childDescriptor)
            guard try identity(of: name, in: parentDescriptor) == expectedIdentity else {
                throw ManagedPathError.itemChanged
            }
            guard Darwin.unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
                throw ManagedPathError.posix(operation: "remove managed directory", code: errno)
            }
        } else {
            guard try identity(of: name, in: parentDescriptor) == expectedIdentity else {
                throw ManagedPathError.itemChanged
            }
            guard Darwin.unlinkat(parentDescriptor, name, 0) == 0 else {
                throw ManagedPathError.posix(operation: "remove managed item", code: errno)
            }
        }
        try verifyRootIdentity()
    }

    private func moveToQuarantine(_ name: String, in parentDescriptor: Int32) throws -> String {
        while true {
            let quarantine = ".skillsmanager-delete-\(UUID().uuidString.lowercased())"
            if Darwin.renameatx_np(
                parentDescriptor,
                name,
                parentDescriptor,
                quarantine,
                UInt32(RENAME_EXCL)
            ) == 0 {
                return quarantine
            }
            if errno == EEXIST {
                continue
            }
            if errno == ENOENT {
                throw ManagedPathError.itemChanged
            }
            throw ManagedPathError.posix(operation: "quarantine managed item", code: errno)
        }
    }

    private func restoreQuarantined(
        _ quarantine: String,
        to original: String,
        in parentDescriptor: Int32
    ) {
        _ = Darwin.renameatx_np(
            parentDescriptor,
            quarantine,
            parentDescriptor,
            original,
            UInt32(RENAME_EXCL)
        )
    }

    private func status(of name: String, in parentDescriptor: Int32) throws -> stat {
        var itemStatus = stat()
        guard Darwin.fstatat(parentDescriptor, name, &itemStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                throw ManagedPathError.itemNotFound
            }
            throw ManagedPathError.posix(operation: "lstat managed item", code: errno)
        }
        return itemStatus
    }

    private func removeDirectoryContents(descriptor: Int32) throws {
        let streamDescriptor = Darwin.dup(descriptor)
        guard streamDescriptor >= 0 else {
            throw ManagedPathError.posix(operation: "duplicate directory descriptor", code: errno)
        }
        guard let directory = Darwin.fdopendir(streamDescriptor) else {
            let code = errno
            Darwin.close(streamDescriptor)
            throw ManagedPathError.posix(operation: "enumerate directory", code: code)
        }
        defer { Darwin.closedir(directory) }

        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = Self.name(of: entry)
            if name == "." || name == ".." {
                continue
            }
            try removeNamedItem(name, from: descriptor)
            errno = 0
        }
        if errno != 0 {
            throw ManagedPathError.posix(operation: "enumerate directory", code: errno)
        }
    }

    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func canonicalPath(for path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(path, &buffer) != nil else {
            throw ManagedPathError.posix(operation: "resolve canonical path", code: errno)
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func fileType(of value: stat) -> mode_t {
        value.st_mode & mode_t(S_IFMT)
    }

    private static func errorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
