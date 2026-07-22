import Darwin
import Foundation

/// A descriptor-backed, owner-only SSOT root supplied by the root bootstrap.
/// The descriptor is duplicated on admission so callers may close their copy.
nonisolated final class VerifiedSSOTRoot: @unchecked Sendable {
    let url: URL
    let identity: ManagedItemIdentity
    private let descriptor: Int32

    init(existingRootURL: URL, descriptor sourceDescriptor: Int32) throws {
        guard existingRootURL.isFileURL else {
            throw ManagedPathError.invalidRoot("not a file URL")
        }
        let url = existingRootURL.standardizedFileURL
        let descriptor = Darwin.fcntl(sourceDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw ManagedPathError.posix(operation: "duplicate verified SSOT root", code: errno)
        }
        do {
            let identity = try Self.validate(
                url: url,
                descriptor: descriptor,
                expectedIdentity: nil
            )
            self.url = url
            self.identity = identity
            self.descriptor = descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func duplicateDescriptor() throws -> Int32 {
        try revalidate()
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw ManagedPathError.posix(operation: "duplicate verified SSOT root", code: errno)
        }
        return duplicate
    }

    func revalidate() throws {
        _ = try Self.validate(url: url, descriptor: descriptor, expectedIdentity: identity)
    }

    static func validateDescriptor(
        _ descriptor: Int32,
        expectedIdentity: ManagedItemIdentity
    ) throws {
        _ = try validate(url: nil, descriptor: descriptor, expectedIdentity: expectedIdentity)
    }

    private static func validate(
        url: URL?,
        descriptor: Int32,
        expectedIdentity: ManagedItemIdentity?
    ) throws -> ManagedItemIdentity {
        var descriptorMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0 else {
            throw ManagedPathError.posix(operation: "inspect verified SSOT root", code: errno)
        }
        let identity = ManagedItemIdentity(descriptorMetadata)
        guard descriptorMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              descriptorMetadata.st_uid == Darwin.geteuid(),
              descriptorMetadata.st_mode & mode_t(0o7777) == mode_t(0o700),
              expectedIdentity.map({ $0 == identity }) ?? true,
              try !hasExtendedACL(descriptor) else {
            throw ManagedPathError.invalidRoot("not an owner-only directory")
        }
        if let url {
            var namedMetadata = stat()
            guard Darwin.lstat(url.path, &namedMetadata) == 0,
                  namedMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  ManagedItemIdentity(namedMetadata) == identity else {
                throw ManagedPathError.rootReplaced
            }
        }
        return identity
    }

    private static func hasExtendedACL(_ descriptor: Int32) throws -> Bool {
        guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw ManagedPathError.posix(operation: "inspect verified SSOT root ACL", code: errno)
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = Darwin.acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard result >= 0 else {
            throw ManagedPathError.posix(operation: "inspect verified SSOT root ACL", code: errno)
        }
        return result == 1
    }
}
