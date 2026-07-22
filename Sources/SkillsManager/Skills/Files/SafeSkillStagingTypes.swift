import Foundation

nonisolated enum SkillInstallConflictPolicy: Sendable {
    case chooseUniqueName
    case replaceExisting
}

nonisolated enum SafeSkillStagingError: LocalizedError, Equatable {
    case invalidDestinationName(String)
    case destinationRootMismatch
    case destinationPathCollision(String, String)
    case sourceChanged(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidDestinationName(let name):
            return "The Skill destination name is unsafe: \(name)"
        case .destinationRootMismatch:
            return "The Skill destination does not match its registered managed root."
        case .destinationPathCollision(let first, let second):
            return "The destination contains conflicting Skill names: \(first) and \(second)"
        case .sourceChanged:
            return "The Skill contents changed while they were being imported. Try again."
        }
    }
}

nonisolated struct SafeSkillCleanupDebt: Equatable, Sendable {
    let url: URL
    let reason: String
}

nonisolated struct SafeSkillStagingFailure: LocalizedError, Equatable, Sendable {
    let originalReason: String
    let cleanupDebts: [SafeSkillCleanupDebt]

    var errorDescription: String? {
        let cleanup = cleanupDebts.map {
            "Cleanup is still needed at \($0.url.path): \($0.reason)"
        }.joined(separator: " ")
        return "\(originalReason) \(cleanup)"
    }
}

nonisolated struct SafeSkillInstallResult: Equatable, Sendable {
    let installedURL: URL
    let cleanupDebts: [SafeSkillCleanupDebt]

    init(installedURL: URL, cleanupDebts: [SafeSkillCleanupDebt] = []) {
        self.installedURL = installedURL
        self.cleanupDebts = cleanupDebts
    }
}
