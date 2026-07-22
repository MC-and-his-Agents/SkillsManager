import Darwin
import Foundation

nonisolated final class SafeSkillArchiveRollbackJournal {
    private enum ItemKind {
        case file
        case directory
    }

    private struct Item {
        var components: [String]
        let identity: ManagedItemIdentity
        let parentIdentity: ManagedItemIdentity
        let kind: ItemKind
    }

    private let rootDescriptor: Int32
    private let rootIdentity: ManagedItemIdentity
    private var items: [Item] = []
    private var itemIndices: [String: Int] = [:]

    init(rootDescriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(rootDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw SafeSkillArchiveError.invalidDestination
        }
        self.rootDescriptor = rootDescriptor
        rootIdentity = ManagedItemIdentity(metadata)
    }

    func openDirectory(_ components: [String], create: Bool) throws -> Int32 {
        var current = try duplicateVerifiedRoot()
        do {
            var prefix: [String] = []
            for component in components {
                let parentIdentity = try identity(of: current)
                prefix.append(component)
                let next: Int32
                if let item = recordedItem(for: prefix) {
                    guard item.kind == .directory,
                          item.parentIdentity == parentIdentity else {
                        throw SafeSkillArchiveError.invalidDestination
                    }
                    next = try openRecordedDirectory(item, in: current)
                } else {
                    guard create else { throw SafeSkillArchiveError.invalidDestination }
                    next = try createDirectory(
                        named: component,
                        components: prefix,
                        in: current,
                        parentIdentity: parentIdentity
                    )
                }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    func recordCompletedFile(
        components: [String],
        descriptor: Int32,
        parentDescriptor: Int32
    ) throws {
        guard let name = components.last, itemIndices[key(for: components)] == nil else {
            throw SafeSkillArchiveError.invalidDestination
        }
        let fileIdentity = try identity(of: descriptor)
        let parentIdentity = try identity(of: parentDescriptor)
        var namedMetadata = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            name,
            &namedMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            ManagedItemIdentity(namedMetadata) == fileIdentity,
            namedMetadata.st_mode & S_IFMT == S_IFREG else {
            throw SafeSkillArchiveError.invalidDestination
        }
        record(Item(
            components: components,
            identity: fileIdentity,
            parentIdentity: parentIdentity,
            kind: .file
        ))
    }

    func rollback() {
        for item in items.reversed() {
            guard let parent = try? openVerifiedParent(of: item) else { continue }
            rollback(item, in: parent)
            Darwin.close(parent)
        }
    }

    private func createDirectory(
        named name: String,
        components: [String],
        in parentDescriptor: Int32,
        parentIdentity: ManagedItemIdentity
    ) throws -> Int32 {
        let temporaryName = ".skillsmanager-tmp-directory-\(UUID().uuidString.lowercased())"
        guard Darwin.mkdirat(parentDescriptor, temporaryName, S_IRWXU) == 0 else {
            throw rollbackPOSIXError()
        }
        var temporaryMetadata = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            temporaryName,
            &temporaryMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            temporaryMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw rollbackPOSIXError()
        }
        let temporaryIdentity = ManagedItemIdentity(temporaryMetadata)
        let temporaryComponents = Array(components.dropLast()) + [temporaryName]
        record(Item(
            components: temporaryComponents,
            identity: temporaryIdentity,
            parentIdentity: parentIdentity,
            kind: .directory
        ))

        let descriptor = Darwin.openat(
            parentDescriptor,
            temporaryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw rollbackPOSIXError() }
        do {
            guard try identity(of: descriptor) == temporaryIdentity else {
                throw SafeSkillArchiveError.invalidDestination
            }
            guard Darwin.renameatx_np(
                parentDescriptor,
                temporaryName,
                parentDescriptor,
                name,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw rollbackPOSIXError()
            }
            moveRecordedItem(from: temporaryComponents, to: components)
            guard try namedIdentity(name, in: parentDescriptor) == temporaryIdentity else {
                throw SafeSkillArchiveError.invalidDestination
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openRecordedDirectory(_ item: Item, in parentDescriptor: Int32) throws -> Int32 {
        let name = item.components[item.components.count - 1]
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw rollbackPOSIXError() }
        do {
            guard try identity(of: descriptor) == item.identity,
                  try namedIdentity(name, in: parentDescriptor) == item.identity else {
                throw SafeSkillArchiveError.invalidDestination
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openVerifiedParent(of item: Item) throws -> Int32 {
        var current = try duplicateVerifiedRoot()
        do {
            let parentComponents = item.components.dropLast()
            var prefix: [String] = []
            for component in parentComponents {
                prefix.append(component)
                guard let parentItem = recordedItem(for: prefix),
                      parentItem.kind == .directory else {
                    throw SafeSkillArchiveError.invalidDestination
                }
                let next = try openRecordedDirectory(parentItem, in: current)
                Darwin.close(current)
                current = next
            }
            guard try identity(of: current) == item.parentIdentity else {
                throw SafeSkillArchiveError.invalidDestination
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func rollback(_ item: Item, in parentDescriptor: Int32) {
        guard let name = item.components.last else { return }
        let quarantine = ".skillsmanager-rollback-\(UUID().uuidString.lowercased())"
        guard Darwin.renameatx_np(
            parentDescriptor,
            name,
            parentDescriptor,
            quarantine,
            UInt32(RENAME_EXCL)
        ) == 0 else { return }

        guard let movedIdentity = try? namedIdentity(quarantine, in: parentDescriptor) else {
            return
        }
        guard movedIdentity == item.identity else {
            restore(quarantine, to: name, identity: movedIdentity, in: parentDescriptor)
            return
        }
        guard (try? namedIdentity(quarantine, in: parentDescriptor)) == item.identity else {
            return
        }

        let flags = item.kind == .directory ? AT_REMOVEDIR : 0
        if Darwin.unlinkat(parentDescriptor, quarantine, flags) != 0, errno != ENOENT {
            restore(quarantine, to: name, identity: item.identity, in: parentDescriptor)
        }
    }

    private func restore(
        _ quarantine: String,
        to name: String,
        identity expectedIdentity: ManagedItemIdentity,
        in parentDescriptor: Int32
    ) {
        guard (try? namedIdentity(quarantine, in: parentDescriptor)) == expectedIdentity else {
            return
        }
        _ = Darwin.renameatx_np(
            parentDescriptor,
            quarantine,
            parentDescriptor,
            name,
            UInt32(RENAME_EXCL)
        )
    }

    private func duplicateVerifiedRoot() throws -> Int32 {
        let descriptor = Darwin.fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw rollbackPOSIXError() }
        do {
            guard try identity(of: descriptor) == rootIdentity else {
                throw SafeSkillArchiveError.invalidDestination
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func identity(of descriptor: Int32) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw rollbackPOSIXError() }
        return ManagedItemIdentity(metadata)
    }

    private func namedIdentity(_ name: String, in descriptor: Int32) throws -> ManagedItemIdentity {
        var metadata = stat()
        guard Darwin.fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw rollbackPOSIXError()
        }
        return ManagedItemIdentity(metadata)
    }

    private func record(_ item: Item) {
        let itemKey = key(for: item.components)
        itemIndices[itemKey] = items.count
        items.append(item)
    }

    private func moveRecordedItem(from oldComponents: [String], to newComponents: [String]) {
        guard let index = itemIndices.removeValue(forKey: key(for: oldComponents)) else { return }
        items[index].components = newComponents
        itemIndices[key(for: newComponents)] = index
    }

    private func recordedItem(for components: [String]) -> Item? {
        itemIndices[key(for: components)].map { items[$0] }
    }

    private func key(for components: [String]) -> String {
        components.joined(separator: "/")
    }
}

private nonisolated func rollbackPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
