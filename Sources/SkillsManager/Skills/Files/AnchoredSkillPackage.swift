import Darwin
import Foundation

nonisolated final class AnchoredSkillPackage {
    let descriptor: Int32
    let displayPath: String

    init(descriptor: Int32, displayPath: String) {
        self.descriptor = descriptor
        self.displayPath = displayPath
    }

    deinit {
        Darwin.close(descriptor)
    }
}

nonisolated enum AnchoredSkillPackageLocator {
    static func locate(
        in rootDescriptor: Int32,
        displayPath: String
    ) throws -> AnchoredSkillPackage {
        if try manifestState(in: rootDescriptor, displayPath: displayPath) == .valid {
            return AnchoredSkillPackage(
                descriptor: try duplicate(rootDescriptor, displayPath: displayPath),
                displayPath: displayPath
            )
        }

        var candidates: [AnchoredSkillPackage] = []
        for name in try directoryNames(in: rootDescriptor, displayPath: displayPath) where !name.hasPrefix(".") {
            let childPath = URL(fileURLWithPath: displayPath).appendingPathComponent(name).path
            guard let child = try openDirectory(named: name, in: rootDescriptor, displayPath: childPath) else {
                continue
            }
            do {
                if try manifestState(in: child, displayPath: childPath) == .valid {
                    candidates.append(AnchoredSkillPackage(descriptor: child, displayPath: childPath))
                } else {
                    Darwin.close(child)
                }
            } catch {
                Darwin.close(child)
                throw error
            }
        }
        guard candidates.count == 1 else {
            throw candidates.isEmpty ? SkillPackageError.missingManifest : SkillPackageError.ambiguousRoots
        }
        return candidates[0]
    }

    private enum ManifestState { case missing, valid }

    private static func manifestState(
        in directoryDescriptor: Int32,
        displayPath: String
    ) throws -> ManifestState {
        var metadata = stat()
        guard Darwin.fstatat(
            directoryDescriptor,
            "SKILL.md",
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return .missing }
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        guard SkillContentFileEnumerator.kind(of: metadata) == .regularFile else {
            throw SkillPackageError.unsafeManifest(displayPath + "/SKILL.md")
        }
        return .valid
    }

    private static func openDirectory(
        named name: String,
        in parentDescriptor: Int32,
        displayPath: String
    ) throws -> Int32? {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOTDIR || errno == ELOOP { return nil }
        guard descriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        return descriptor
    }

    private static func duplicate(_ descriptor: Int32, displayPath: String) throws -> Int32 {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        return duplicate
    }

    private static func directoryNames(
        in descriptor: Int32,
        displayPath: String
    ) throws -> [String] {
        let duplicate = try duplicate(descriptor, displayPath: displayPath)
        guard let directory = Darwin.fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: code)
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        Darwin.rewinddir(directory)
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        return names
    }
}
