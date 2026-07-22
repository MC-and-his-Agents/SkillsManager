import Foundation

nonisolated enum ManagedSkillRemovalError: LocalizedError, Equatable {
    case targetOutsideManagedRoots

    var errorDescription: String? {
        switch self {
        case .targetOutsideManagedRoots:
            "The skill is not a direct child of a registered skills directory."
        }
    }
}

/// Removes one skill only when its parent resolves to an explicitly registered skills root.
nonisolated enum ManagedSkillRemoval {
    static func remove(targetURL: URL, managedRoot: ManagedRootReference) throws {
        guard targetURL.isFileURL else {
            throw ManagedSkillRemovalError.targetOutsideManagedRoots
        }

        let rawComponents = (targetURL.path as NSString).pathComponents
        guard !rawComponents.contains("."), !rawComponents.contains("..") else {
            throw ManagedSkillRemovalError.targetOutsideManagedRoots
        }

        let target = targetURL.standardizedFileURL
        let root = try managedRoot.verifiedRootURL()
        guard target.deletingLastPathComponent().path == root.path else {
            throw ManagedSkillRemovalError.targetOutsideManagedRoots
        }

        try ManagedPathGuard(rootURL: root).removeItem(at: target)
    }
}
