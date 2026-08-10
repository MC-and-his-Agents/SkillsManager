import Foundation

@MainActor enum SkillBatchUpdatePresentation {
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
                title: String(localized: "Waiting", bundle: .module),
                detail: nil,
                systemImage: "clock",
                accessibilityValue: String(
                    localized: LocalizedStringResource( "%@, waiting",
                    defaultValue: "\(item.displayName), waiting",
                    bundle: .module
                ))
            )
        case .checking:
            Row(
                title: String(localized: "Checking", bundle: .module),
                detail: String(localized: "Reading the local Skill and remote source.", bundle: .module),
                systemImage: "arrow.clockwise",
                accessibilityValue: String(
                    localized: LocalizedStringResource( "%@, checking for updates",
                    defaultValue: "\(item.displayName), checking for updates",
                    bundle: .module
                ))
            )
        case .ready:
            Row(
                title: String(localized: "Update available", bundle: .module),
                detail: String(localized: "This Skill can be updated safely.", bundle: .module),
                systemImage: "arrow.down.circle",
                accessibilityValue: String(
                    localized: LocalizedStringResource( "%@, update available",
                    defaultValue: "\(item.displayName), update available",
                    bundle: .module
                ))
            )
        case .decisionRequired:
            Row(
                title: String(localized: "Copy decision required", bundle: .module),
                detail: String(localized: "Choose how to handle every modified Copy.", bundle: .module),
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                accessibilityValue: String(
                    localized: LocalizedStringResource( "%@, Copy decision required",
                    defaultValue: "\(item.displayName), Copy decision required",
                    bundle: .module
                ))
            )
        case .preparing:
            Row(
                title: String(localized: "Preparing", bundle: .module),
                detail: String(localized: "Revalidating the Skill and remote source.", bundle: .module),
                systemImage: "arrow.triangle.2.circlepath",
                accessibilityValue: String(
                    localized: LocalizedStringResource( "%@, preparing update",
                    defaultValue: "\(item.displayName), preparing update",
                    bundle: .module
                ))
            )
        case .updating:
            Row(
                title: String(localized: "Updating", bundle: .module),
                detail: String(localized: "Backing up, replacing, and refreshing distribution.", bundle: .module),
                systemImage: "arrow.down.circle.fill",
                accessibilityValue: String(
                    localized: LocalizedStringResource( "%@, updating",
                    defaultValue: "\(item.displayName), updating",
                    bundle: .module
                ))
            )
        case .result(let result, let detail):
            Row(
                title: result.title,
                detail: detail ?? result.defaultDetail,
                systemImage: result.systemImage,
                accessibilityValue: String(
                    localized: LocalizedStringResource( "%@, %@",
                    defaultValue: "\(item.displayName), \(result.title)",
                    bundle: .module
                ))
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
        if summary.total == 0 {
            return String(localized: "No managed Skills.", bundle: .module)
        }
        let values = SkillBatchUpdateResult.allCases.compactMap { result in
            let count = summary[result]
            return count == 0
                ? nil
                : String(
                    localized: LocalizedStringResource( "%@: %lld",
                    defaultValue: "\(result.title): \(count)",
                    bundle: .module
                ))
        }
        if values.isEmpty {
            return String(
                localized: LocalizedStringResource( "0 of %lld complete.",
                defaultValue: "0 of \(summary.total) complete.",
                bundle: .module
            ))
        }
        return String(
            localized: LocalizedStringResource( "%lld of %lld complete. %@",
            defaultValue: "\(summary.completed) of \(summary.total) complete. \(values.joined(separator: ", "))",
            bundle: .module
        ))
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
        if scopeKey == "global" {
            return String(localized: "Global shared target", bundle: .module)
        }
        let prefix = "agent:"
        guard scopeKey.hasPrefix(prefix) else {
            return String(localized: "Managed Copy target", bundle: .module)
        }
        let key = String(scopeKey.dropFirst(prefix.count))
        return SkillPlatform.allCases.first(where: { $0.storageKey == key })?.rawValue
            ?? String(localized: "Managed Agent target", bundle: .module)
    }
}

@MainActor extension SkillBatchUpdateResult {
    var title: String {
        switch self {
        case .updated: String(localized: "Updated", bundle: .module)
        case .upToDate: String(localized: "Up to date", bundle: .module)
        case .forked: String(localized: "Updated; local changes kept as Fork", bundle: .module)
        case .conflict: String(localized: "Conflict", bundle: .module)
        case .skipped: String(localized: "Skipped", bundle: .module)
        case .cancelled: String(localized: "Cancelled", bundle: .module)
        case .failed: String(localized: "Failed", bundle: .module)
        case .needsAttention: String(localized: "Needs attention", bundle: .module)
        }
    }

    var defaultDetail: String? {
        switch self {
        case .updated: String(localized: "The managed Skill and its distribution are current.", bundle: .module)
        case .upToDate: String(localized: "No update was required.", bundle: .module)
        case .forked: String(localized: "The parent Skill was updated and local changes are independent.", bundle: .module)
        case .conflict: String(localized: "Recheck after resolving local or remote changes.", bundle: .module)
        case .skipped: String(localized: "This available update was not selected.", bundle: .module)
        case .cancelled: String(localized: "No update was started for this Skill.", bundle: .module)
        case .failed: String(localized: "The operation did not complete.", bundle: .module)
        case .needsAttention: String(localized: "Review this Skill before trying again.", bundle: .module)
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

@MainActor extension ManagedSkillUpdateCopyDecision {
    var batchDisplayName: String {
        switch self {
        case .discard: String(localized: "Discard local changes", bundle: .module)
        case .fork: String(localized: "Keep changes as a Fork", bundle: .module)
        case .cancel: String(localized: "Cancel this Skill update", bundle: .module)
    }
}
}
