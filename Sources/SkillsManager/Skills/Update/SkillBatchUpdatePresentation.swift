import Foundation

nonisolated enum SkillBatchUpdatePresentation {
    struct Row: Equatable, Sendable {
        let title: String
        let detail: String?
        let systemImage: String
        let accessibilityValue: String
    }

    struct Controls: Equatable, Sendable {
        let canCheck: Bool
        let canSelectReady: Bool
        let canUpdate: Bool
        let canStop: Bool
        let canClose: Bool
    }

    static func row(for item: SkillBatchUpdateItem) -> Row {
        switch item.phase {
        case .queued:
            Row(
                title: "Waiting",
                detail: nil,
                systemImage: "clock",
                accessibilityValue: "\(item.displayName), waiting"
            )
        case .checking:
            Row(
                title: "Checking",
                detail: "Reading the local Skill and remote source.",
                systemImage: "arrow.clockwise",
                accessibilityValue: "\(item.displayName), checking for updates"
            )
        case .ready:
            Row(
                title: "Update available",
                detail: "This Skill can be updated safely.",
                systemImage: "arrow.down.circle",
                accessibilityValue: "\(item.displayName), update available"
            )
        case .decisionRequired:
            Row(
                title: "Copy decision required",
                detail: "Choose how to handle every modified Copy.",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                accessibilityValue: "\(item.displayName), Copy decision required"
            )
        case .preparing:
            Row(
                title: "Preparing",
                detail: "Revalidating the Skill and remote source.",
                systemImage: "arrow.triangle.2.circlepath",
                accessibilityValue: "\(item.displayName), preparing update"
            )
        case .updating:
            Row(
                title: "Updating",
                detail: "Backing up, replacing, and refreshing distribution.",
                systemImage: "arrow.down.circle.fill",
                accessibilityValue: "\(item.displayName), updating"
            )
        case .result(let result, let detail):
            Row(
                title: result.title,
                detail: detail ?? result.defaultDetail,
                systemImage: result.systemImage,
                accessibilityValue: "\(item.displayName), \(result.title)"
            )
        }
    }

    static func controls(
        state: SkillBatchUpdateRunState,
        itemCount: Int,
        selectedCount: Int,
        selectionsComplete: Bool
    ) -> Controls {
        let running = state == .checking || state == .executing
        return Controls(
            canCheck: !running && itemCount > 0 && {
                if case .blocked = state { return false }
                return true
            }(),
            canSelectReady: state == .review,
            canUpdate: state == .review
                && selectedCount > 0
                && selectionsComplete,
            canStop: running,
            canClose: !running
        )
    }

    static func summary(_ summary: SkillBatchUpdateSummary) -> String {
        if summary.total == 0 { return "No managed Skills." }
        let values = SkillBatchUpdateResult.allCases.compactMap { result in
            let count = summary[result]
            return count == 0 ? nil : "\(result.title): \(count)"
        }
        if values.isEmpty {
            return "0 of \(summary.total) complete."
        }
        return "\(summary.completed) of \(summary.total) complete. "
            + values.joined(separator: ", ")
    }

    static func filteredItems(
        _ items: [SkillBatchUpdateItem],
        query: String
    ) -> [SkillBatchUpdateItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    static func scopeTitle(_ scopeKey: String) -> String {
        if scopeKey == "global" { return "Global shared target" }
        let prefix = "agent:"
        guard scopeKey.hasPrefix(prefix) else { return "Managed Copy target" }
        let key = String(scopeKey.dropFirst(prefix.count))
        return SkillPlatform.allCases.first(where: { $0.storageKey == key })?.rawValue
            ?? "Managed Agent target"
    }
}

nonisolated extension SkillBatchUpdateResult {
    var title: String {
        switch self {
        case .updated: "Updated"
        case .upToDate: "Up to date"
        case .forked: "Updated; local changes kept as Fork"
        case .conflict: "Conflict"
        case .skipped: "Skipped"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .needsAttention: "Needs attention"
        }
    }

    var defaultDetail: String? {
        switch self {
        case .updated: "The managed Skill and its distribution are current."
        case .upToDate: "No update was required."
        case .forked: "The parent Skill was updated and local changes are independent."
        case .conflict: "Recheck after resolving local or remote changes."
        case .skipped: "This available update was not selected."
        case .cancelled: "No update was started for this Skill."
        case .failed: "The operation did not complete."
        case .needsAttention: "Review this Skill before trying again."
        }
    }

    var systemImage: String {
        switch self {
        case .updated, .upToDate: "checkmark.circle"
        case .forked: "arrow.triangle.branch"
        case .conflict, .needsAttention: "exclamationmark.triangle"
        case .skipped: "forward"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.octagon"
        }
    }
}

nonisolated extension ManagedSkillUpdateCopyDecision {
    var batchDisplayName: String {
        switch self {
        case .discard: "Discard local changes"
        case .fork: "Keep changes as a Fork"
        case .cancel: "Cancel this Skill update"
        }
    }
}
