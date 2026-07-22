import Darwin
import Foundation

extension SkillContentSnapshot {
    nonisolated static func withDestinationParent<T>(
        for relativePath: String,
        rootDescriptor: Int32,
        body: (Int32, String) throws -> T
    ) throws -> T {
        var components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let fileName = components.popLast(), !fileName.isEmpty else {
            throw SkillContentSnapshotError.fileChanged(path: relativePath)
        }
        let parentDescriptor = try openDestinationDirectory(
            components,
            rootDescriptor: rootDescriptor,
            displayPath: relativePath
        )
        defer { Darwin.close(parentDescriptor) }
        return try body(parentDescriptor, fileName)
    }

    nonisolated static func openDestinationDirectory(
        _ components: [String],
        rootDescriptor: Int32,
        displayPath: String
    ) throws -> Int32 {
        var parentDescriptor = Darwin.dup(rootDescriptor)
        guard parentDescriptor >= 0 else {
            throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
        }
        for component in components {
            if Darwin.mkdirat(parentDescriptor, component, S_IRWXU) != 0, errno != EEXIST {
                Darwin.close(parentDescriptor)
                throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: errno)
            }
            let next = Darwin.openat(
                parentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                let code = errno
                Darwin.close(parentDescriptor)
                throw SkillContentSnapshotError.fileSystemFailure(path: displayPath, code: code)
            }
            Darwin.close(parentDescriptor)
            parentDescriptor = next
        }
        return parentDescriptor
    }
}
