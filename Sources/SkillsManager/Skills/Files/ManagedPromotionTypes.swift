import Foundation

nonisolated enum ManagedPromotionResult: Equatable {
    case committed
    case committedWithCleanupDebt(URL, ManagedPathError)
}

nonisolated struct ManagedPromotionIndeterminate: LocalizedError, Equatable, Sendable {
    let targetURL: URL
    let recoveryURL: URL?

    var errorDescription: String? {
        let recovery = recoveryURL.map {
            " Existing contents were preserved for recovery at \($0.path)."
        } ?? ""
        return "The Skill promotion completed, but its final state changed concurrently. "
            + "Inspect \(targetURL.path) before retrying.\(recovery)"
    }
}

nonisolated struct ManagedPathGuardTestHooks {
    var beforeNoReplaceCommit: () throws -> Void = {}
    var afterNoReplaceCommit: () throws -> Void = {}
    var beforeReplaceCommit: () throws -> Void = {}
    var afterReplaceCommit: () throws -> Void = {}
    var beforeEquivalentSiblingCheck: () throws -> Void = {}
    var beforeCleanup: () throws -> Void = {}
    var afterCleanup: () throws -> Void = {}
    var beforeQuarantineMove: (String) throws -> Void = { _ in }
    var afterQuarantineMove: (String, String) throws -> Void = { _, _ in }
}
