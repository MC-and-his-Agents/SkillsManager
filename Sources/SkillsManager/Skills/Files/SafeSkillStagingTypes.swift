import Foundation

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
