import Darwin
import Foundation

nonisolated struct LibraryRootLayout: Sendable {
    static let managementDirectoryName = ".SkillsManager"
    static let databaseFileName = "manager.sqlite"
    static let ssotDirectoryName = "skills"
    static let bootstrapMarkerName = "bootstrap.marker"

    let homeURL: URL
    let managementRootURL: URL
    let databaseURL: URL
    let ssotRootURL: URL

    init(homeURL: URL) {
        self.homeURL = homeURL.standardizedFileURL
        managementRootURL = self.homeURL.appendingPathComponent(
            Self.managementDirectoryName,
            isDirectory: true
        )
        databaseURL = managementRootURL.appendingPathComponent(Self.databaseFileName)
        ssotRootURL = managementRootURL.appendingPathComponent(
            Self.ssotDirectoryName,
            isDirectory: true
        )
    }
}

nonisolated struct LibraryBootstrapMarker: Codable, Equatable, Sendable {
    let formatVersion: Int
    let bootstrapKind: LibraryBootstrapKind
    let bootstrapID: UUID

    init(kind: LibraryBootstrapKind, bootstrapID: UUID = UUID()) {
        formatVersion = 1
        bootstrapKind = kind
        self.bootstrapID = bootstrapID
    }
}

nonisolated struct LibraryBootstrapMarkerHandle: Sendable {
    let marker: LibraryBootstrapMarker
    let identity: ManagedItemIdentity
}

nonisolated enum LibraryRootBootstrapError: Error, Equatable {
    case invalidHome
    case invalidManagementRoot
    case unexpectedManagementEntry(String)
    case invalidMarker
    case markerIdentityChanged
    case itemAlreadyExists(String)
    case itemMissing(String)
    case posix(operation: String, code: Int32)
}

nonisolated struct LibraryManagementRootAdmission {
    let root: VerifiedSSOTRoot
    let created: Bool
}

nonisolated enum LibraryRootBootstrap {
    static func openOrCreateManagementRoot(
        layout: LibraryRootLayout
    ) throws -> LibraryManagementRootAdmission {
        let home = try openAnchoredHome(layout.homeURL)
        defer { Darwin.close(home) }
        var metadata = stat()
        if Darwin.fstatat(
            home,
            LibraryRootLayout.managementDirectoryName,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            guard errno == ENOENT else { throw posix("classify management root") }
            if Darwin.mkdirat(
                home,
                LibraryRootLayout.managementDirectoryName,
                mode_t(0o700)
            ) != 0, errno != EEXIST {
                throw posix("create management root")
            }
            try SSOTDurability.syncDirectory(home)
            return LibraryManagementRootAdmission(
                root: try openVerifiedDirectory(
                    named: LibraryRootLayout.managementDirectoryName,
                    parent: home,
                    url: layout.managementRootURL
                ),
                created: true
            )
        }
        return LibraryManagementRootAdmission(
            root: try openVerifiedDirectory(
                named: LibraryRootLayout.managementDirectoryName,
                parent: home,
                url: layout.managementRootURL
            ),
            created: false
        )
    }

    static func managementEntryNames(_ root: VerifiedSSOTRoot) throws -> [String] {
        let descriptor = try root.duplicateDescriptor()
        defer { Darwin.close(descriptor) }
        return try SafeSourceTree.names(in: descriptor, displayPath: ".SkillsManager")
            .map(\.precomposedStringWithCanonicalMapping)
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func requireOnlyManagementEntries(
        _ allowed: Set<String>,
        root: VerifiedSSOTRoot
    ) throws {
        if let unknown = try managementEntryNames(root).first(where: { !allowed.contains($0) }) {
            throw LibraryRootBootstrapError.unexpectedManagementEntry(unknown)
        }
    }

    static func createMarker(
        _ marker: LibraryBootstrapMarker,
        root: VerifiedSSOTRoot
    ) throws -> LibraryBootstrapMarkerHandle {
        let rootDescriptor = try root.duplicateDescriptor()
        defer { Darwin.close(rootDescriptor) }
        let descriptor = Darwin.openat(
            rootDescriptor,
            LibraryRootLayout.bootstrapMarkerName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw LibraryRootBootstrapError.itemAlreadyExists(
                    LibraryRootLayout.bootstrapMarkerName
                )
            }
            throw posix("create bootstrap marker")
        }
        defer { Darwin.close(descriptor) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(marker)
        guard payload.count <= 4_096 else { throw LibraryRootBootstrapError.invalidMarker }
        try write(payload, descriptor: descriptor)
        try SSOTDurability.syncFile(descriptor)
        try SSOTDurability.syncDirectory(rootDescriptor)
        let identity = try validateMarker(
            descriptor: descriptor,
            rootDescriptor: rootDescriptor
        )
        try root.revalidate()
        return LibraryBootstrapMarkerHandle(marker: marker, identity: identity)
    }

    static func openMarker(root: VerifiedSSOTRoot) throws -> LibraryBootstrapMarkerHandle {
        let rootDescriptor = try root.duplicateDescriptor()
        defer { Darwin.close(rootDescriptor) }
        let descriptor = Darwin.openat(
            rootDescriptor,
            LibraryRootLayout.bootstrapMarkerName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw LibraryRootBootstrapError.itemMissing(
                    LibraryRootLayout.bootstrapMarkerName
                )
            }
            throw posix("open bootstrap marker")
        }
        defer { Darwin.close(descriptor) }
        let identity = try validateMarker(
            descriptor: descriptor,
            rootDescriptor: rootDescriptor
        )
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              0...4_096 ~= metadata.st_size else {
            throw LibraryRootBootstrapError.invalidMarker
        }
        let bytes = try read(count: Int(metadata.st_size), descriptor: descriptor)
        guard try ManagedItemIdentityCodec.capture(descriptor: descriptor) == identity,
              let marker = try? JSONDecoder().decode(LibraryBootstrapMarker.self, from: bytes),
              marker.formatVersion == 1 else {
            throw LibraryRootBootstrapError.invalidMarker
        }
        return LibraryBootstrapMarkerHandle(marker: marker, identity: identity)
    }

    static func removeMarker(
        expectedIdentity: ManagedItemIdentity,
        root: VerifiedSSOTRoot
    ) throws {
        let rootDescriptor = try root.duplicateDescriptor()
        defer { Darwin.close(rootDescriptor) }
        var metadata = stat()
        guard Darwin.fstatat(
            rootDescriptor,
            LibraryRootLayout.bootstrapMarkerName,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return }
            throw posix("inspect bootstrap marker for removal")
        }
        guard ManagedItemIdentity(metadata) == expectedIdentity else {
            throw LibraryRootBootstrapError.markerIdentityChanged
        }
        guard Darwin.unlinkat(
            rootDescriptor,
            LibraryRootLayout.bootstrapMarkerName,
            0
        ) == 0 else {
            throw posix("remove bootstrap marker")
        }
        try SSOTDurability.syncDirectory(rootDescriptor)
        try root.revalidate()
    }

    static func createOrOpenSSOT(
        layout: LibraryRootLayout,
        root: VerifiedSSOTRoot
    ) throws -> VerifiedSSOTRoot {
        let rootDescriptor = try root.duplicateDescriptor()
        defer { Darwin.close(rootDescriptor) }
        if Darwin.mkdirat(
            rootDescriptor,
            LibraryRootLayout.ssotDirectoryName,
            mode_t(0o700)
        ) != 0, errno != EEXIST {
            throw posix("create SSOT root")
        }
        try SSOTDurability.syncDirectory(rootDescriptor)
        return try openVerifiedDirectory(
            named: LibraryRootLayout.ssotDirectoryName,
            parent: rootDescriptor,
            url: layout.ssotRootURL
        )
    }

    static func openExistingSSOT(
        layout: LibraryRootLayout,
        root: VerifiedSSOTRoot
    ) throws -> VerifiedSSOTRoot {
        let rootDescriptor = try root.duplicateDescriptor()
        defer { Darwin.close(rootDescriptor) }
        return try openVerifiedDirectory(
            named: LibraryRootLayout.ssotDirectoryName,
            parent: rootDescriptor,
            url: layout.ssotRootURL
        )
    }

    static func itemExists(named name: String, root: VerifiedSSOTRoot) throws -> Bool {
        let descriptor = try root.duplicateDescriptor()
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        if Darwin.fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return true
        }
        if errno == ENOENT { return false }
        throw posix("classify \(name)")
    }

    private static func openAnchoredHome(_ homeURL: URL) throws -> Int32 {
        guard homeURL.isFileURL, homeURL.path.hasPrefix("/"), homeURL.path != "/" else {
            throw LibraryRootBootstrapError.invalidHome
        }
        let parent = Darwin.open(
            homeURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else { throw posix("open home parent") }
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(
            parent,
            homeURL.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posix("open home") }
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              Darwin.fstatat(
                parent,
                homeURL.lastPathComponent,
                &named,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              held.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              held.st_uid == Darwin.geteuid(),
              ManagedItemIdentity(held) == ManagedItemIdentity(named) else {
            Darwin.close(descriptor)
            throw LibraryRootBootstrapError.invalidHome
        }
        return descriptor
    }

    private static func openVerifiedDirectory(
        named name: String,
        parent: Int32,
        url: URL
    ) throws -> VerifiedSSOTRoot {
        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posix("open \(name)") }
        defer { Darwin.close(descriptor) }
        return try VerifiedSSOTRoot(existingRootURL: url, descriptor: descriptor)
    }

    private static func validateMarker(
        descriptor: Int32,
        rootDescriptor: Int32
    ) throws -> ManagedItemIdentity {
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              Darwin.fstatat(
                rootDescriptor,
                LibraryRootLayout.bootstrapMarkerName,
                &named,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              held.st_uid == Darwin.geteuid(),
              held.st_nlink == 1,
              held.st_mode & mode_t(0o7777) == mode_t(0o600),
              ManagedItemIdentity(held) == ManagedItemIdentity(named) else {
            throw LibraryRootBootstrapError.invalidMarker
        }
        return ManagedItemIdentity(held)
    }

    private static func write(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                guard count > 0 else { throw posix("write bootstrap marker") }
                offset += count
            }
        }
        guard Darwin.ftruncate(descriptor, off_t(data.count)) == 0 else {
            throw posix("truncate bootstrap marker")
        }
    }

    private static func read(count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < count {
                let readCount = Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    count - offset,
                    off_t(offset)
                )
                guard readCount > 0 else { throw posix("read bootstrap marker") }
                offset += readCount
            }
        }
        return data
    }

    private static func posix(_ operation: String) -> LibraryRootBootstrapError {
        .posix(operation: operation, code: errno)
    }
}
