import Foundation

nonisolated enum SkillPackageError: LocalizedError, Equatable {
    case unsupportedRoot
    case missingManifest
    case ambiguousRoots
    case unsafeManifest(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRoot:
            return "The selected item must be a regular folder, not a symbolic link."
        case .missingManifest:
            return "The selected item doesn’t contain a SKILL.md file."
        case .ambiguousRoots:
            return "The selected item contains more than one Skill folder."
        case .unsafeManifest(let path):
            return "The Skill manifest must be a regular file: \(path)"
        }
    }
}

nonisolated struct SkillPackageLocator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func locateSkillRoot(in selectedRoot: URL) throws -> URL {
        let root = selectedRoot.standardizedFileURL
        guard try isDirectory(root), try !isSymbolicLink(root) else {
            throw SkillPackageError.unsupportedRoot
        }

        let directManifest = root.appendingPathComponent("SKILL.md", isDirectory: false)
        if fileManager.fileExists(atPath: directManifest.path) {
            try validateManifest(directManifest)
            return root
        }

        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var candidates: [URL] = []
        for child in children {
            guard try isDirectory(child), try !isSymbolicLink(child) else { continue }
            let manifest = child.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: manifest.path) else { continue }
            try validateManifest(manifest)
            candidates.append(child.standardizedFileURL)
        }

        switch candidates.count {
        case 0:
            throw SkillPackageError.missingManifest
        case 1:
            return candidates[0]
        default:
            throw SkillPackageError.ambiguousRoots
        }
    }

    private func validateManifest(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SkillPackageError.unsafeManifest(url.path)
        }
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }
}
