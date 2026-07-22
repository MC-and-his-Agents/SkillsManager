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
    case cleanupFailed(String)
    case removalFailed(
        partiallyDeleted: Bool,
        recoveryPath: String?,
        restored: Bool,
        cause: String
    )
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
        case .cleanupFailed(let reason): "Cleanup failed: \(reason)"
        case .removalFailed(let partiallyDeleted, let recoveryPath, let restored, let cause):
            Self.removalFailureDescription(
                partiallyDeleted: partiallyDeleted,
                recoveryPath: recoveryPath,
                restored: restored,
                cause: cause
            )
        case .posix(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }

    private static func removalFailureDescription(
        partiallyDeleted: Bool,
        recoveryPath: String?,
        restored: Bool,
        cause: String
    ) -> String {
        let state = partiallyDeleted
            ? "Deletion stopped after some contents were removed."
            : "Deletion stopped before any contents were removed."
        let recovery: String
        if restored {
            recovery = recoveryPath.map { "The remaining item was restored at \($0)." }
                ?? "The remaining item was restored to its original name."
        } else if let recoveryPath {
            recovery = "The remaining item could not be restored; recover it from \(recoveryPath)."
        } else {
            recovery = "No remaining item could be located for automatic recovery."
        }
        return "\(state) \(recovery) Cause: \(cause)"
    }
}
nonisolated struct ManagedItemIdentity: Equatable, Sendable {
    fileprivate let device: UInt64
    fileprivate let inode: UInt64
    fileprivate let fileType: UInt32
    fileprivate let generation: UInt64
    init(_ value: stat) {
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
nonisolated struct ManagedPromotionIndeterminate: LocalizedError, Equatable, Sendable {
    let targetURL: URL
    let recoveryURL: URL?

    var errorDescription: String? {
        let recovery = recoveryURL.map {
            " Existing contents were preserved for recovery at \($0.path)."
        } ?? ""
        return "The Skill promotion completed, but its final state changed concurrently. "
            + "Inspect \(targetURL.path) before retrying.\(recovery)"
    }
}
nonisolated struct ManagedPathGuardTestHooks {
    var beforeNoReplaceCommit: () throws -> Void = {}
    var afterNoReplaceCommit: () throws -> Void = {}
    var beforeReplaceCommit: () throws -> Void = {}
    var afterReplaceCommit: () throws -> Void = {}
    var beforeCleanup: () throws -> Void = {}
    var afterCleanup: () throws -> Void = {}
    var beforeQuarantineMove: (String) throws -> Void = { _ in }
    var afterQuarantineMove: (String, String) throws -> Void = { _, _ in }
}
nonisolated final class ManagedPathGuard {
    typealias FileIdentity = ManagedItemIdentity
    struct ManagedName {
        let value: String
    }

    private struct PromotionNames {
        let staged: String
        let target: String
    }
    private let rootPath: String
    private let canonicalRootPath: String
    private let rootIdentity: FileIdentity
    let rootDescriptor: Int32
    let hooks: ManagedPathGuardTestHooks
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
    func itemIdentity(at targetURL: URL) throws -> ManagedItemIdentity? {
        try verifyRootIdentity()
        let name = try managedName(for: targetURL)
        try verifyRootIdentity()
        return try identityIfPresent(of: name.value, in: rootDescriptor)
    }
    func promoteStagedItemIfAbsent(
        at stagedURL: URL,
        to targetURL: URL,
        expectedStaged: ManagedItemIdentity,
        validateStaged: (URL) throws -> Void
    ) throws {
        let names = try promotionNames(stagedURL: stagedURL, targetURL: targetURL)
        guard try identity(of: names.staged, in: rootDescriptor) == expectedStaged else {
            throw ManagedPathError.itemChanged
        }
        try hooks.beforeNoReplaceCommit()
        try verifyRootIdentity()
        try validateStaged(stagedURL)
        guard try identity(of: names.staged, in: rootDescriptor) == expectedStaged else {
            throw ManagedPathError.itemChanged
        }
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
        do {
            try hooks.afterNoReplaceCommit()
            try verifyCommittedTarget(
                names: names,
                expectedStaged: expectedStaged,
                validateStaged: validateStaged
            )
        } catch {
            throw promotionIndeterminate(names: names, recoveryIdentity: expectedStaged)
        }
    }
    func replaceStagedItem(
        at stagedURL: URL,
        to targetURL: URL,
        expectedStaged: ManagedItemIdentity,
        expectedTarget: ManagedItemIdentity,
        validateStaged: (URL) throws -> Void
    ) throws -> ManagedPromotionResult {
        let names = try promotionNames(stagedURL: stagedURL, targetURL: targetURL)
        guard try identity(of: names.staged, in: rootDescriptor) == expectedStaged else {
            throw ManagedPathError.itemChanged
        }
        try hooks.beforeReplaceCommit()
        try validateStaged(stagedURL)
        guard try identity(of: names.staged, in: rootDescriptor) == expectedStaged,
              try identityIfPresent(of: names.target, in: rootDescriptor) == expectedTarget else {
            throw ManagedPathError.itemChanged
        }
        try verifyRootIdentity()
        guard swap(names) == 0 else {
            throw ManagedPathError.posix(operation: "swap staged and existing items", code: errno)
        }
        do {
            try hooks.afterReplaceCommit()
            try verifyCommittedTarget(
                names: names,
                expectedStaged: expectedStaged,
                validateStaged: validateStaged
            )
            guard try identityIfPresent(of: names.staged, in: rootDescriptor) == expectedTarget else {
                throw ManagedPathError.itemChanged
            }
        } catch {
            throw promotionIndeterminate(names: names, recoveryIdentity: expectedTarget)
        }
        return try cleanReplacedItem(
            names: names,
            expectedStaged: expectedStaged,
            expectedTarget: expectedTarget,
            validateStaged: validateStaged
        )
    }
    func managedName(for targetURL: URL) throws -> ManagedName {
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
    func verifyRootIdentity() throws {
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
        expectedStaged: ManagedItemIdentity,
        expectedTarget: ManagedItemIdentity,
        validateStaged: (URL) throws -> Void
    ) throws -> ManagedPromotionResult {
        let cleanupResult: ManagedPromotionResult
        do {
            try hooks.beforeCleanup()
            let oldStatus = try status(of: names.staged, in: rootDescriptor)
            guard FileIdentity(oldStatus) == expectedTarget else {
                return try verifiedCommittedResult(
                    .committedWithCleanupDebt(cleanupURL(for: names), .itemChanged),
                    names: names,
                    expectedStaged: expectedStaged,
                    expectedTarget: expectedTarget,
                    validateStaged: validateStaged
                )
            }
            try removeQuarantinedItem(names.staged, status: oldStatus, in: rootDescriptor)
            try hooks.afterCleanup()
            cleanupResult = .committed
        } catch let cleanupError as ManagedPathError {
            cleanupResult = .committedWithCleanupDebt(cleanupURL(for: names), cleanupError)
        } catch {
            cleanupResult = .committedWithCleanupDebt(
                cleanupURL(for: names),
                .cleanupFailed(error.localizedDescription)
            )
        }
        return try verifiedCommittedResult(
            cleanupResult,
            names: names,
            expectedStaged: expectedStaged,
            expectedTarget: expectedTarget,
            validateStaged: validateStaged
        )
    }

    private func verifiedCommittedResult(
        _ result: ManagedPromotionResult,
        names: PromotionNames,
        expectedStaged: ManagedItemIdentity,
        expectedTarget: ManagedItemIdentity,
        validateStaged: (URL) throws -> Void
    ) throws -> ManagedPromotionResult {
        do {
            try verifyCommittedTarget(
                names: names,
                expectedStaged: expectedStaged,
                validateStaged: validateStaged
            )
            return result
        } catch {
            throw promotionIndeterminate(names: names, recoveryIdentity: expectedTarget)
        }
    }

    private func verifyCommittedTarget(
        names: PromotionNames,
        expectedStaged: ManagedItemIdentity,
        validateStaged: (URL) throws -> Void
    ) throws {
        try verifyRootIdentity()
        guard try identityIfPresent(of: names.target, in: rootDescriptor) == expectedStaged else {
            throw ManagedPathError.itemChanged
        }
        try validateStaged(URL(fileURLWithPath: rootPath).appendingPathComponent(names.target))
        guard try identityIfPresent(of: names.target, in: rootDescriptor) == expectedStaged else {
            throw ManagedPathError.itemChanged
        }
        try verifyRootIdentity()
    }

    private func promotionIndeterminate(
        names: PromotionNames,
        recoveryIdentity: ManagedItemIdentity
    ) -> ManagedPromotionIndeterminate {
        let recoveryURL = (try? identity(of: names.staged, in: rootDescriptor)) == recoveryIdentity
            ? cleanupURL(for: names)
            : nil
        return ManagedPromotionIndeterminate(
            targetURL: URL(fileURLWithPath: rootPath).appendingPathComponent(names.target),
            recoveryURL: recoveryURL
        )
    }

    private func cleanupURL(for names: PromotionNames) -> URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent(names.staged)
    }

    func identity(of name: String, in parentDescriptor: Int32) throws -> FileIdentity {
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

    private static func canonicalPath(for path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(path, &buffer) != nil else {
            throw ManagedPathError.posix(operation: "resolve canonical path", code: errno)
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func fileType(of value: stat) -> mode_t {
        value.st_mode & mode_t(S_IFMT)
    }

    private static func errorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
