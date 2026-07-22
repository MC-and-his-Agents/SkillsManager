import Darwin
import Foundation

nonisolated enum ManagedRootReferenceError: LocalizedError, Equatable {
    case invalidRoot(String)
    case rootChanged

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let reason):
            "Invalid managed root: \(reason)"
        case .rootChanged:
            "The registered skills directory changed after it was scanned."
        }
    }
}

/// Immutable identity captured when a skills root is registered or scanned.
nonisolated struct ManagedRootReference: Hashable, Sendable {
    private struct Identity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
        let type: UInt16
        let generation: UInt32

        init(_ metadata: stat) {
            device = UInt64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
            type = UInt16(metadata.st_mode & mode_t(S_IFMT))
            generation = metadata.st_gen
        }
    }

    let registeredURL: URL
    let canonicalURL: URL
    private let registeredIdentity: Identity
    private let canonicalIdentity: Identity

    static func capture(at rootURL: URL) throws -> ManagedRootReference {
        guard rootURL.isFileURL else {
            throw ManagedRootReferenceError.invalidRoot("not a file URL")
        }
        let registeredURL = rootURL.standardizedFileURL
        let registeredMetadata = try metadata(at: registeredURL)
        let registeredType = registeredMetadata.st_mode & mode_t(S_IFMT)
        guard registeredType == S_IFDIR || registeredType == S_IFLNK else {
            throw ManagedRootReferenceError.invalidRoot("not a directory or directory link")
        }

        let canonicalURL = try canonicalURL(for: registeredURL)
        let canonicalMetadata = try metadata(at: canonicalURL)
        guard canonicalMetadata.st_mode & mode_t(S_IFMT) == S_IFDIR else {
            throw ManagedRootReferenceError.invalidRoot("canonical target is not a directory")
        }
        return ManagedRootReference(
            registeredURL: registeredURL,
            canonicalURL: canonicalURL,
            registeredIdentity: Identity(registeredMetadata),
            canonicalIdentity: Identity(canonicalMetadata)
        )
    }

    func verifiedRootURL() throws -> URL {
        try verifiedRoot().url
    }

    func verifiedRoot() throws -> (url: URL, identity: ManagedItemIdentity) {
        let canonicalMetadata = try Self.metadata(at: canonicalURL)
        guard Identity(try Self.metadata(at: registeredURL)) == registeredIdentity,
              try Self.canonicalURL(for: registeredURL) == canonicalURL,
              Identity(canonicalMetadata) == canonicalIdentity else {
            throw ManagedRootReferenceError.rootChanged
        }
        return (canonicalURL, ManagedItemIdentity(canonicalMetadata))
    }

    private static func metadata(at url: URL) throws -> stat {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw ManagedRootReferenceError.invalidRoot(String(cString: strerror(errno)))
        }
        return value
    }

    private static func canonicalURL(for url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(url.path, &buffer) != nil else {
            throw ManagedRootReferenceError.invalidRoot(String(cString: strerror(errno)))
        }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).standardizedFileURL
    }
}
