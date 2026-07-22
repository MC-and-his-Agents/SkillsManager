import Darwin
import Foundation

/// A physical deletion plan frozen from the same snapshot whose fingerprint
/// authorized cleanup. Entries excluded from fingerprints are never adopted.
nonisolated struct SSOTJournalDeletionManifest {
    struct DirectoryLink {
        let name: String
        let identity: ManagedItemIdentity
    }

    struct RegularFileSnapshot: Equatable {
        let identity: ManagedItemIdentity
        let size: off_t
        let modificationSeconds: time_t
        let modificationNanoseconds: Int
        let statusChangeSeconds: time_t
        let statusChangeNanoseconds: Int

        init(_ file: SkillContentFileEnumerator.DiscoveredFile) {
            identity = ManagedItemIdentity(persistedComponents: .init(
                device: UInt64(file.device),
                inode: UInt64(file.inode),
                fileType: UInt32(S_IFREG),
                generation: UInt64(file.generation)
            ))
            size = off_t(file.byteCount)
            modificationSeconds = file.modificationSeconds
            modificationNanoseconds = file.modificationNanoseconds
            statusChangeSeconds = file.statusChangeSeconds
            statusChangeNanoseconds = file.statusChangeNanoseconds
        }

        init?(_ metadata: stat) {
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_size >= 0 else { return nil }
            identity = ManagedItemIdentity(metadata)
            size = metadata.st_size
            modificationSeconds = metadata.st_mtimespec.tv_sec
            modificationNanoseconds = metadata.st_mtimespec.tv_nsec
            statusChangeSeconds = metadata.st_ctimespec.tv_sec
            statusChangeNanoseconds = metadata.st_ctimespec.tv_nsec
        }
    }

    enum Item {
        case file(RegularFileSnapshot)
        case directory(ManagedItemIdentity)

        var identity: ManagedItemIdentity {
            switch self {
            case .file(let snapshot): snapshot.identity
            case .directory(let identity): identity
            }
        }
    }

    struct Entry {
        let parentKey: String
        let name: String
        let relativePath: String
        let item: Item
    }

    struct Directory {
        let key: String
        let identity: ManagedItemIdentity
        let ancestry: [DirectoryLink]
        var entries: [String: Item]
    }

    private enum RemovalVisit {
        case directory(String)
        case entry(Entry)
    }

    let topIdentity: ManagedItemIdentity
    let directories: [String: Directory]
    let removalOrder: [Entry]

    static func freeze(
        snapshot: SkillContentSnapshot,
        topName: String,
        topIdentity: ManagedItemIdentity,
        maximumDepth: Int
    ) throws -> Self {
        let top = DirectoryLink(name: topName, identity: topIdentity)
        var directories = ["": Directory(
            key: "", identity: topIdentity, ancestry: [top], entries: [:]
        )]
        for record in snapshot.sourceDirectories {
            guard record.steps.count <= maximumDepth, let last = record.steps.last else {
                throw ManagedPathError.itemChanged
            }
            let key = path(record.steps.map(\.name))
            directories[key] = Directory(
                key: key,
                identity: managedIdentity(last.identity, fileType: S_IFDIR),
                ancestry: [top] + record.steps.map {
                    DirectoryLink(
                        name: $0.name,
                        identity: managedIdentity($0.identity, fileType: S_IFDIR)
                    )
                },
                entries: [:]
            )
        }

        var entries: [Entry] = []
        for record in snapshot.sourceDirectories {
            guard let last = record.steps.last else { throw ManagedPathError.itemChanged }
            let components = record.steps.map(\.name)
            let parentKey = path(Array(components.dropLast()))
            let name = last.name
            let item = Item.directory(managedIdentity(last.identity, fileType: S_IFDIR))
            try append(item, name: name, parentKey: parentKey, to: &directories, entries: &entries)
        }
        for file in snapshot.discoveredFiles {
            let parentKey = path(file.directorySteps.map(\.name))
            try append(
                .file(RegularFileSnapshot(file)),
                name: file.fileName,
                parentKey: parentKey,
                to: &directories,
                entries: &entries
            )
        }
        return Self(
            topIdentity: topIdentity,
            directories: directories,
            removalOrder: orderedEntries(entries)
        )
    }

    static func requireChildren(
        of directory: Directory,
        remaining: Set<String>,
        descriptor: Int32
    ) throws {
        var directoryMetadata = stat()
        guard Darwin.fstat(descriptor, &directoryMetadata) == 0,
              ManagedItemIdentity(directoryMetadata) == directory.identity else {
            throw ManagedPathError.itemChanged
        }
        let names = try SafeSourceTree.names(in: descriptor, displayPath: "journal-owned item")
        guard Set(names) == remaining else { throw ManagedPathError.itemChanged }
        for name in remaining {
            guard let item = directory.entries[name] else { throw ManagedPathError.itemChanged }
            var metadata = stat()
            guard Darwin.fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ManagedPathError.itemChanged
            }
            switch item {
            case .file(let expected):
                guard RegularFileSnapshot(metadata) == expected else {
                    throw ManagedPathError.itemChanged
                }
            case .directory(let expected):
                guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      ManagedItemIdentity(metadata) == expected else {
                    throw ManagedPathError.itemChanged
                }
            }
        }
    }

    private static func append(
        _ item: Item,
        name: String,
        parentKey: String,
        to directories: inout [String: Directory],
        entries: inout [Entry]
    ) throws {
        guard !SkillContentExclusions.contains(
            name,
            isDirectory: ifDirectory(item)
        ), var parent = directories[parentKey], parent.entries[name] == nil else {
            throw ManagedPathError.itemChanged
        }
        parent.entries[name] = item
        directories[parentKey] = parent
        let relativePath = parentKey.isEmpty ? name : "\(parentKey)/\(name)"
        entries.append(.init(
            parentKey: parentKey,
            name: name,
            relativePath: relativePath,
            item: item
        ))
    }

    private static func path(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    private static func orderedEntries(_ entries: [Entry]) -> [Entry] {
        let byParent = Dictionary(grouping: entries, by: \.parentKey)
        var pending: [RemovalVisit] = [.directory("")]
        var result: [Entry] = []
        while let visit = pending.popLast() {
            switch visit {
            case .entry(let entry):
                result.append(entry)
            case .directory(let key):
                let children = (byParent[key] ?? []).sorted {
                    $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
                }
                for entry in children.reversed() {
                    if case .directory = entry.item {
                        pending.append(.entry(entry))
                        pending.append(.directory(entry.relativePath))
                    } else {
                        pending.append(.entry(entry))
                    }
                }
            }
        }
        return result
    }

    private static func ifDirectory(_ item: Item) -> Bool {
        if case .directory = item { return true }
        return false
    }

    private static func managedIdentity(
        _ identity: SafeSourceTree.Identity,
        fileType: mode_t
    ) -> ManagedItemIdentity {
        ManagedItemIdentity(persistedComponents: .init(
            device: UInt64(identity.device),
            inode: UInt64(identity.inode),
            fileType: UInt32(fileType),
            generation: UInt64(identity.generation)
        ))
    }
}
