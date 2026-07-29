import Foundation

nonisolated struct SkillBatchUpdateCatalogItem: Hashable, Sendable {
    let skillID: SkillID
    let displayName: String
}

nonisolated enum SkillBatchUpdateResult: String, CaseIterable, Sendable {
    case updated
    case upToDate
    case forked
    case conflict
    case skipped
    case cancelled
    case failed
    case needsAttention
}

nonisolated enum SkillBatchUpdateItemPhase: Equatable, Sendable {
    case queued
    case checking
    case ready
    case decisionRequired
    case preparing
    case updating
    case result(SkillBatchUpdateResult, String?)
}

nonisolated struct SkillBatchUpdateScope: Identifiable, Equatable, Sendable {
    let scopeKey: String
    let title: String

    var id: String { scopeKey }
}

nonisolated struct SkillBatchUpdateItem: Identifiable, Equatable, Sendable {
    let skillID: SkillID
    let displayName: String
    var phase: SkillBatchUpdateItemPhase = .queued
    var snapshot: ManagedSkillUpdateCheckSnapshot?
    var scopes: [SkillBatchUpdateScope] = []
    var decisions: [String: ManagedSkillUpdateCopyDecision] = [:]
    var isSelected = false

    var id: SkillID { skillID }

    var finalResult: SkillBatchUpdateResult? {
        guard case .result(let result, _) = phase else { return nil }
        return result
    }

    var isActionable: Bool {
        phase == .ready || phase == .decisionRequired
    }

    var hasCompleteDecisions: Bool {
        phase != .decisionRequired
            || Set(decisions.keys) == Set(scopes.map(\.scopeKey))
    }

    var allowsRetry: Bool {
        switch finalResult {
        case .conflict, .cancelled, .failed, .needsAttention: true
        case .updated, .upToDate, .forked, .skipped, nil: false
        }
    }
}

nonisolated struct SkillBatchUpdateSummary: Equatable, Sendable {
    let total: Int
    let counts: [SkillBatchUpdateResult: Int]

    init(items: [SkillBatchUpdateItem]) {
        total = items.count
        counts = Dictionary(
            grouping: items.compactMap(\.finalResult),
            by: { $0 }
        ).mapValues(\.count)
    }

    var completed: Int { counts.values.reduce(0, +) }
    var isComplete: Bool { completed == total }

    subscript(_ result: SkillBatchUpdateResult) -> Int {
        counts[result, default: 0]
    }
}

nonisolated enum SkillBatchUpdateRunState: Equatable, Sendable {
    case blocked(String)
    case empty
    case idle
    case checking
    case review
    case executing
    case completed
}

nonisolated struct SkillBatchUpdateDependencies: Sendable {
    let check:
        @Sendable (SkillID) async throws -> ManagedSkillUpdateCheckSnapshot
    let prepare:
        @Sendable (ManagedSkillUpdateCheckSnapshot) async throws
            -> ManagedSkillUpdateExecutionPreview
    let cancel:
        @Sendable (ManagedSkillUpdateExecutionToken) async -> Void
    let confirm:
        @Sendable (
            ManagedSkillUpdateExecutionToken,
            [ManagedSkillUpdateDecisionSelection]
        ) async throws -> ManagedSkillUpdateExecutionResult

    static func live(
        writer: JournaledSSOTWriter,
        remote: RemoteSkillClient
    ) -> Self {
        let checkService = ManagedSkillUpdateCheckService(
            writer: writer,
            remote: remote
        )
        let executionService = ManagedSkillUpdateExecutionService(
            writer: writer,
            remote: remote
        )
        return Self(
            check: { try await checkService.check($0) },
            prepare: { try await executionService.prepare($0) },
            cancel: { await executionService.cancel($0) },
            confirm: { token, selections in
                try await executionService.confirm(token, selections: selections)
            }
        )
    }
}
