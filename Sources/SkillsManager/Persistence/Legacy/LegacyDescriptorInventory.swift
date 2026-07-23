import CryptoKit
import Darwin
import Foundation

nonisolated final class LegacyHeldDescriptor: @unchecked Sendable {
    let value: Int32

    init(_ value: Int32) { self.value = value }
    deinit { Darwin.close(value) }
}

nonisolated struct LegacyFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        generation = UInt64(metadata.st_gen)
    }
}

nonisolated struct LegacyMetadataSnapshot: Equatable, Sendable {
    let identity: LegacyFileIdentity
    let mode: mode_t
    let owner: uid_t
    let size: Int64

    init(_ metadata: stat) {
        identity = LegacyFileIdentity(metadata)
        mode = metadata.st_mode
        owner = metadata.st_uid
        size = metadata.st_size
    }
}

nonisolated struct LegacyDirectorySnapshot: Equatable, Sendable {
    let identity: LegacyFileIdentity
    let mode: mode_t
    let owner: uid_t

    init(_ metadata: stat) {
        identity = LegacyFileIdentity(metadata)
        mode = metadata.st_mode
        owner = metadata.st_uid
    }
}

nonisolated final class LegacyCapturedFile: @unchecked Sendable {
    let locator: String
    let name: String
    let parent: LegacyHeldDescriptor
    let descriptor: LegacyHeldDescriptor
    let snapshot: LegacyMetadataSnapshot
    let bytes: Data
    let digest: Data

    init(
        locator: String,
        name: String,
        parent: LegacyHeldDescriptor,
        maximumBytes: Int
    ) throws {
        let file = Darwin.openat(parent.value, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw LegacyMigrationFailure(.legacyPathChanged, locator: locator) }
        let descriptor = LegacyHeldDescriptor(file)
        let metadata = try legacyMetadata(descriptor: file, locator: locator)
        try requireLegacyFile(metadata, maximumBytes: maximumBytes, locator: locator)
        let bytes = try readLegacyBytes(
            descriptor: file,
            expectedSize: Int(metadata.st_size),
            locator: locator
        )
        let afterRead = try legacyMetadata(descriptor: file, locator: locator)
        guard LegacyMetadataSnapshot(afterRead) == LegacyMetadataSnapshot(metadata) else {
            throw LegacyMigrationFailure(.legacyInventoryChanged, locator: locator)
        }
        self.locator = locator
        self.name = name
        self.parent = parent
        self.descriptor = descriptor
        self.snapshot = LegacyMetadataSnapshot(metadata)
        self.bytes = bytes
        self.digest = Data(SHA256.hash(data: bytes))
    }

    func validateUnchanged() throws {
        let held = try legacyMetadata(descriptor: descriptor.value, locator: locator)
        let current = try legacyMetadata(parent: parent.value, name: name, locator: locator)
        try requireLegacyFile(held, maximumBytes: Int.max, locator: locator)
        try requireLegacyFile(current, maximumBytes: Int.max, locator: locator)
        guard LegacyMetadataSnapshot(held) == snapshot,
              LegacyMetadataSnapshot(current) == snapshot else {
            throw LegacyMigrationFailure(.legacyInventoryChanged, locator: locator)
        }
        let currentBytes = try readLegacyBytes(
            descriptor: descriptor.value,
            expectedSize: bytes.count,
            locator: locator
        )
        guard Data(SHA256.hash(data: currentBytes)) == digest else {
            throw LegacyMigrationFailure(.legacyInventoryChanged, locator: locator)
        }
    }
}

nonisolated final class LegacyDirectoryChain: @unchecked Sendable {
    private struct Anchor {
        let name: String
        let parent: LegacyHeldDescriptor
        let descriptor: LegacyHeldDescriptor
        let snapshot: LegacyDirectorySnapshot
    }

    private struct Missing {
        let name: String
        let parent: LegacyHeldDescriptor
    }

    let legacyRoot: LegacyHeldDescriptor?
    let skillStateDirectory: LegacyHeldDescriptor?
    private let anchors: [Anchor]
    private let missing: Missing?

    static func capture(homeURL: URL) throws -> LegacyDirectoryChain {
        let home = homeURL.standardizedFileURL
        guard home.isFileURL, home.path.hasPrefix("/"), home.path != "/" else {
            throw LegacyMigrationFailure(.legacyPathChanged)
        }
        let parentPath = home.deletingLastPathComponent().path
        let parentFD = Darwin.open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentFD >= 0 else { throw LegacyMigrationFailure(.legacyPathChanged) }
        let parent = LegacyHeldDescriptor(parentFD)
        let homeName = home.lastPathComponent
        let homeDescriptor = try openDirectory(named: homeName, parent: parent)
        var anchors = [try anchor(named: homeName, parent: parent, descriptor: homeDescriptor)]
        var current = homeDescriptor
        var root: LegacyHeldDescriptor?
        var skillState: LegacyHeldDescriptor?
        var missing: Missing?

        for component in ["Library", "Application Support", "SkillsManager", "skill-state"] {
            switch try optionalDirectory(named: component, parent: current) {
            case .present(let descriptor):
                anchors.append(try anchor(named: component, parent: current, descriptor: descriptor))
                current = descriptor
                if component == "SkillsManager" { root = descriptor }
                if component == "skill-state" { skillState = descriptor }
            case .missing:
                missing = Missing(name: component, parent: current)
                return LegacyDirectoryChain(
                    legacyRoot: root,
                    skillStateDirectory: skillState,
                    anchors: anchors,
                    missing: missing
                )
            }
        }
        return LegacyDirectoryChain(
            legacyRoot: root,
            skillStateDirectory: skillState,
            anchors: anchors,
            missing: nil
        )
    }

    func validateUnchanged() throws {
        for anchor in anchors {
            let held = try legacyMetadata(descriptor: anchor.descriptor.value, locator: nil)
            let current = try legacyMetadata(
                parent: anchor.parent.value,
                name: anchor.name,
                locator: nil
            )
            try requireLegacyDirectory(held)
            try requireLegacyDirectory(current)
            guard LegacyDirectorySnapshot(held) == anchor.snapshot,
                  LegacyDirectorySnapshot(current) == anchor.snapshot else {
                throw LegacyMigrationFailure(.legacyPathChanged)
            }
        }
        if let missing {
            var metadata = stat()
            guard Darwin.fstatat(
                missing.parent.value,
                missing.name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) != 0, errno == ENOENT else {
                throw LegacyMigrationFailure(.legacyPathChanged)
            }
        }
    }

    private init(
        legacyRoot: LegacyHeldDescriptor?,
        skillStateDirectory: LegacyHeldDescriptor?,
        anchors: [Anchor],
        missing: Missing?
    ) {
        self.legacyRoot = legacyRoot
        self.skillStateDirectory = skillStateDirectory
        self.anchors = anchors
        self.missing = missing
    }

    private enum OptionalDirectory { case present(LegacyHeldDescriptor), missing }

    private static func optionalDirectory(
        named name: String,
        parent: LegacyHeldDescriptor
    ) throws -> OptionalDirectory {
        var metadata = stat()
        if Darwin.fstatat(parent.value, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return .missing }
            throw LegacyMigrationFailure(.legacyPathChanged)
        }
        let descriptor = try openDirectory(named: name, parent: parent)
        return .present(descriptor)
    }

    private static func openDirectory(
        named name: String,
        parent: LegacyHeldDescriptor
    ) throws -> LegacyHeldDescriptor {
        let fd = Darwin.openat(parent.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw LegacyMigrationFailure(.legacyPathChanged) }
        let descriptor = LegacyHeldDescriptor(fd)
        try requireLegacyDirectory(legacyMetadata(descriptor: fd, locator: nil))
        return descriptor
    }

    private static func anchor(
        named name: String,
        parent: LegacyHeldDescriptor,
        descriptor: LegacyHeldDescriptor
    ) throws -> Anchor {
        Anchor(
            name: name,
            parent: parent,
            descriptor: descriptor,
            snapshot: LegacyDirectorySnapshot(try legacyMetadata(descriptor: descriptor.value, locator: nil))
        )
    }
}

nonisolated func legacyDirectoryNames(_ descriptor: LegacyHeldDescriptor) throws -> [String] {
    let enumerationDescriptor = Darwin.openat(
        descriptor.value,
        ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard enumerationDescriptor >= 0, let directory = Darwin.fdopendir(enumerationDescriptor) else {
        if enumerationDescriptor >= 0 { Darwin.close(enumerationDescriptor) }
        throw LegacyMigrationFailure(.legacyPathChanged)
    }
    defer { Darwin.closedir(directory) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = Darwin.readdir(directory) else {
            guard errno == 0 else { throw LegacyMigrationFailure(.legacyPathChanged) }
            break
        }
        let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(validatingCString: $0)
            }
        }
        guard let name else { throw LegacyMigrationFailure(.legacyPathChanged) }
        if name != "." && name != ".." { names.append(name) }
    }
    return names
}

private nonisolated func legacyMetadata(
    descriptor: Int32,
    locator: String?
) throws -> stat {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
        throw LegacyMigrationFailure(.legacyPathChanged, locator: locator)
    }
    return metadata
}

private nonisolated func legacyMetadata(
    parent: Int32,
    name: String,
    locator: String?
) throws -> stat {
    var metadata = stat()
    guard Darwin.fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw LegacyMigrationFailure(.legacyPathChanged, locator: locator)
    }
    return metadata
}

private nonisolated func requireLegacyDirectory(_ metadata: stat) throws {
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
        throw LegacyMigrationFailure(.legacyPathChanged)
    }
    try requireLegacyOwnership(metadata, locator: nil)
}

private nonisolated func requireLegacyFile(
    _ metadata: stat,
    maximumBytes: Int,
    locator: String
) throws {
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw LegacyMigrationFailure(.legacyPathChanged, locator: locator)
    }
    try requireLegacyOwnership(metadata, locator: locator)
    guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
        throw LegacyMigrationFailure(.legacyResourceLimitExceeded, locator: locator)
    }
}

private nonisolated func requireLegacyOwnership(
    _ metadata: stat,
    locator: String?
) throws {
    guard metadata.st_uid == Darwin.geteuid(), metadata.st_mode & 0o022 == 0 else {
        throw LegacyMigrationFailure(.legacyPermissionInvalid, locator: locator)
    }
}

private nonisolated func readLegacyBytes(
    descriptor: Int32,
    expectedSize: Int,
    locator: String
) throws -> Data {
    var bytes = Data(count: expectedSize)
    var offset = 0
    try bytes.withUnsafeMutableBytes { buffer in
        while offset < expectedSize {
            let count = Darwin.pread(
                descriptor,
                buffer.baseAddress?.advanced(by: offset),
                expectedSize - offset,
                off_t(offset)
            )
            guard count > 0 else {
                throw LegacyMigrationFailure(.legacyInventoryChanged, locator: locator)
            }
            offset += count
        }
    }
    var extra: UInt8 = 0
    guard Darwin.pread(descriptor, &extra, 1, off_t(expectedSize)) == 0 else {
        throw LegacyMigrationFailure(.legacyInventoryChanged, locator: locator)
    }
    return bytes
}
