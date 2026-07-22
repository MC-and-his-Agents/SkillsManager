import Darwin
import Foundation

nonisolated struct ManagedItemIdentityPersistedComponents: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let fileType: UInt32
    let generation: UInt64
}

nonisolated enum ManagedItemIdentityCodecError: LocalizedError, Equatable {
    case invalidPayload
    case unsupportedVersion(Int)
    case unsupportedFileType(UInt32)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "The persisted file identity is invalid."
        case .unsupportedVersion(let version):
            "The persisted file identity version \(version) is not supported."
        case .unsupportedFileType(let fileType):
            "The persisted file identity contains unsupported file type \(fileType)."
        }
    }
}

nonisolated enum ManagedItemIdentityCodec {
    static let encodedByteCount = 32
    private static let currentVersion: UInt32 = 1

    static func encode(_ identity: ManagedItemIdentity) throws -> Data {
        let value = identity.persistedComponents
        try validate(value)
        var data = Data(capacity: encodedByteCount)
        data.appendBigEndian(currentVersion)
        data.appendBigEndian(value.device)
        data.appendBigEndian(value.inode)
        data.appendBigEndian(value.fileType)
        data.appendBigEndian(value.generation)
        return data
    }

    static func decode(_ data: Data) throws -> ManagedItemIdentity {
        guard data.count == encodedByteCount else {
            throw ManagedItemIdentityCodecError.invalidPayload
        }
        return try data.withUnsafeBytes { bytes in
            let version = UInt32(bigEndian: bytes.loadUnaligned(as: UInt32.self))
            guard version == currentVersion else {
                throw ManagedItemIdentityCodecError.unsupportedVersion(Int(version))
            }
            let value = ManagedItemIdentityPersistedComponents(
                device: UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt64.self)),
                inode: UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt64.self)),
                fileType: UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 20, as: UInt32.self)),
                generation: UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
            )
            try validate(value)
            return ManagedItemIdentity(persistedComponents: value)
        }
    }

    static func capture(descriptor: Int32) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ManagedPathError.posix(operation: "inspect managed item identity", code: errno)
        }
        return ManagedItemIdentity(metadata)
    }

    static func revalidate(
        descriptor: Int32,
        expected: ManagedItemIdentity
    ) throws {
        guard try capture(descriptor: descriptor) == expected else {
            throw ManagedPathError.itemChanged
        }
    }

    private static func validate(_ identity: ManagedItemIdentityPersistedComponents) throws {
        let allowedTypes = [UInt32(S_IFREG), UInt32(S_IFDIR), UInt32(S_IFLNK)]
        guard allowedTypes.contains(identity.fileType) else {
            throw ManagedItemIdentityCodecError.unsupportedFileType(identity.fileType)
        }
    }
}

private extension Data {
    mutating nonisolated func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
