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
    typealias GuardFactory = (URL) throws -> ManagedPathGuard

    static func remove(
        targetURL: URL,
        managedRoot: ManagedRootReference,
        beforeGuard: () throws -> Void = {},
        guardFactory: @escaping GuardFactory = { try ManagedPathGuard(rootURL: $0) }
    ) throws {
        guard targetURL.isFileURL else {
            throw ManagedSkillRemovalError.targetOutsideManagedRoots
        }

        let rawComponents = (targetURL.path as NSString).pathComponents
        guard !rawComponents.contains("."), !rawComponents.contains("..") else {
            throw ManagedSkillRemovalError.targetOutsideManagedRoots
        }

        let target = targetURL.standardizedFileURL
        let verifiedRoot = try managedRoot.verifiedRoot()
        let root = verifiedRoot.url
        guard target.deletingLastPathComponent().path == root.path else {
            throw ManagedSkillRemovalError.targetOutsideManagedRoots
        }

        try beforeGuard()
        let guardrail = try guardFactory(root)
        try guardrail.verifyRootIdentity(expected: verifiedRoot.identity)
        try guardrail.removeItem(at: target)
    }
}
