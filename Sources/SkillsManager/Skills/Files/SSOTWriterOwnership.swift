import Darwin
import Foundation
import Synchronization

@_silgen_name("flock")
private nonisolated func ssotFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

private nonisolated enum SSOTWriterProcessRegistry {
    static let owners = Mutex<[ManagedItemIdentity: SSOTWriterOwner]>([:])

    static func claim(
        rootIdentity: ManagedItemIdentity,
        owner: SSOTWriterOwner
    ) -> SSOTWriterOwner? {
        owners.withLock { owners in
            if let existing = owners[rootIdentity] { return existing }
            owners[rootIdentity] = owner
            return nil
        }
    }

    static func release(rootIdentity: ManagedItemIdentity) {
        _ = owners.withLock { $0.removeValue(forKey: rootIdentity) }
    }
}

nonisolated struct SSOTWriterOwner: Codable, Equatable, Sendable {
    let processID: Int32

    static var current: Self { Self(processID: Darwin.getpid()) }
}

nonisolated enum SSOTWriterOwnershipError: LocalizedError, Equatable {
    case busy(owner: SSOTWriterOwner?)
    case invalidLockFile
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .busy(let owner):
            owner.map { "The SSOT writer is already owned by process \($0.processID)." }
                ?? "The SSOT writer is already owned by another process."
        case .invalidLockFile:
            "The SSOT writer lock is not a regular owner-only file."
        case .posix(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

nonisolated final class SSOTWriterOwnership: @unchecked Sendable {
    static let lockFileName = "manager.lock"

    let owner: SSOTWriterOwner
    let lockIdentity: ManagedItemIdentity
    private let authorityGuard: ManagedPathGuard
    private let rootIdentity: ManagedItemIdentity
    private let descriptor: Int32

    private init(
        owner: SSOTWriterOwner,
        lockIdentity: ManagedItemIdentity,
        authorityGuard: ManagedPathGuard,
        rootIdentity: ManagedItemIdentity,
        descriptor: Int32
    ) {
        self.owner = owner
        self.lockIdentity = lockIdentity
        self.authorityGuard = authorityGuard
        self.rootIdentity = rootIdentity
        self.descriptor = descriptor
    }

    deinit {
        _ = ssotFileLock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        SSOTWriterProcessRegistry.release(rootIdentity: rootIdentity)
    }

    static func acquire(
        using guardValue: ManagedPathGuard,
        owner: SSOTWriterOwner = .current
    ) throws -> SSOTWriterOwnership {
        try guardValue.verifyRootIdentity()
        let rootIdentity = try ManagedItemIdentityCodec.capture(
            descriptor: guardValue.rootDescriptor
        )
        try VerifiedSSOTRoot.validateDescriptor(
            guardValue.rootDescriptor,
            expectedIdentity: rootIdentity
        )
        if let existing = SSOTWriterProcessRegistry.claim(
            rootIdentity: rootIdentity,
            owner: owner
        ) {
            throw SSOTWriterOwnershipError.busy(owner: existing)
        }
        var registryClaimed = true
        defer {
            if registryClaimed {
                SSOTWriterProcessRegistry.release(rootIdentity: rootIdentity)
            }
        }
        let descriptor = Darwin.openat(
            guardValue.rootDescriptor,
            lockFileName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posix("open SSOT writer lock") }

        do {
            let identity = try validateLockFile(
                descriptor: descriptor,
                rootDescriptor: guardValue.rootDescriptor
            )
            guard ssotFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw SSOTWriterOwnershipError.busy(owner: readOwner(descriptor))
                }
                throw SSOTWriterOwnershipError.posix(
                    operation: "lock SSOT writer",
                    code: code
                )
            }
            do {
                try guardValue.verifyRootIdentity()
                guard try namedIdentity(in: guardValue.rootDescriptor) == identity else {
                    throw SSOTWriterOwnershipError.invalidLockFile
                }
                try write(owner: owner, to: descriptor)
                try SSOTDurability.syncFile(descriptor)
                try guardValue.verifyRootIdentity()
                guard try namedIdentity(in: guardValue.rootDescriptor) == identity else {
                    throw SSOTWriterOwnershipError.invalidLockFile
                }
                registryClaimed = false
                return SSOTWriterOwnership(
                    owner: owner,
                    lockIdentity: identity,
                    authorityGuard: guardValue,
                    rootIdentity: rootIdentity,
                    descriptor: descriptor
                )
            } catch {
                _ = ssotFileLock(descriptor, LOCK_UN)
                throw error
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func validateForMutation() throws {
        try authorityGuard.verifyRootIdentity(expected: rootIdentity)
        try VerifiedSSOTRoot.validateDescriptor(
            authorityGuard.rootDescriptor,
            expectedIdentity: rootIdentity
        )
        guard try Self.validateLockFile(
            descriptor: descriptor,
            rootDescriptor: authorityGuard.rootDescriptor
        ) == lockIdentity else {
            throw SSOTWriterOwnershipError.invalidLockFile
        }
    }

    private static func validateLockFile(
        descriptor: Int32,
        rootDescriptor: Int32
    ) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posix("inspect SSOT writer lock")
        }
        let permissions = metadata.st_mode & mode_t(0o7777)
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1,
              permissions == mode_t(S_IRUSR | S_IWUSR) else {
            throw SSOTWriterOwnershipError.invalidLockFile
        }
        let identity = ManagedItemIdentity(metadata)
        guard try namedIdentity(in: rootDescriptor) == identity else {
            throw SSOTWriterOwnershipError.invalidLockFile
        }
        return identity
    }

    private static func namedIdentity(in rootDescriptor: Int32) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.fstatat(
            rootDescriptor,
            lockFileName,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw posix("inspect named SSOT writer lock")
        }
        return ManagedItemIdentity(metadata)
    }

    private static func write(owner: SSOTWriterOwner, to descriptor: Int32) throws {
        let payload = Data("\(owner.processID)\n".utf8)
        guard Darwin.ftruncate(descriptor, 0) == 0 else {
            throw posix("truncate SSOT writer owner")
        }
        var written = 0
        try payload.withUnsafeBytes { bytes in
            while written < bytes.count {
                let count = Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written,
                    off_t(written)
                )
                guard count >= 0 else { throw posix("write SSOT writer owner") }
                written += count
            }
        }
    }

    private static func readOwner(_ descriptor: Int32) -> SSOTWriterOwner? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = Darwin.pread(descriptor, &bytes, bytes.count, 0)
        guard count > 0,
              let value = String(bytes: bytes.prefix(Int(count)), encoding: .utf8),
              let processID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              processID > 0 else {
            return nil
        }
        return SSOTWriterOwner(processID: processID)
    }

    private static func posix(_ operation: String) -> SSOTWriterOwnershipError {
        .posix(operation: operation, code: errno)
    }
}
