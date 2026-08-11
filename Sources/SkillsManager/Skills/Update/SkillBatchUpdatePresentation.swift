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
                title: String(localized: "Waiting", bundle: SkillsManagerLocalizationResources.bundle),
                detail: nil,
                systemImage: "clock",
                accessibilityValue: String(
                    localized: LocalizedStringResource(
            "\(item.displayName), waiting",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            )
        case .checking:
            Row(
                title: String(localized: "Checking", bundle: SkillsManagerLocalizationResources.bundle),
                detail: String(localized: "Reading the local Skill and remote source.", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "arrow.clockwise",
                accessibilityValue: String(
                    localized: LocalizedStringResource(
            "\(item.displayName), checking for updates",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            )
        case .ready:
            Row(
                title: String(localized: "Update available", bundle: SkillsManagerLocalizationResources.bundle),
                detail: String(localized: "This Skill can be updated safely.", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "arrow.down.circle",
                accessibilityValue: String(
                    localized: LocalizedStringResource(
            "\(item.displayName), update available",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            )
        case .decisionRequired:
            Row(
                title: String(localized: "Copy decision required", bundle: SkillsManagerLocalizationResources.bundle),
                detail: String(localized: "Choose how to handle every modified Copy.", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                accessibilityValue: String(
                    localized: LocalizedStringResource(
            "\(item.displayName), Copy decision required",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            )
        case .preparing:
            Row(
                title: String(localized: "Preparing", bundle: SkillsManagerLocalizationResources.bundle),
                detail: String(localized: "Revalidating the Skill and remote source.", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "arrow.triangle.2.circlepath",
                accessibilityValue: String(
                    localized: LocalizedStringResource(
            "\(item.displayName), preparing update",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            )
        case .updating:
            Row(
                title: String(localized: "Updating", bundle: SkillsManagerLocalizationResources.bundle),
                detail: String(localized: "Backing up, replacing, and refreshing distribution.", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "arrow.down.circle.fill",
                accessibilityValue: String(
                    localized: LocalizedStringResource(
            "\(item.displayName), updating",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            )
        case .result(let result, let detail):
            Row(
                title: result.title,
                detail: detail ?? result.defaultDetail,
                systemImage: result.systemImage,
                accessibilityValue: String(
                    localized: LocalizedStringResource(
            "\(item.displayName), \(result.title)",
            bundle: SkillsManagerLocalizationResources.bundle
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
            return String(localized: "No managed Skills.", bundle: SkillsManagerLocalizationResources.bundle)
        }
        let values = SkillBatchUpdateResult.allCases.compactMap { result in
            let count = summary[result]
            return count == 0
                ? nil
                : String(
                    localized: LocalizedStringResource(
            "\(result.title): \(count)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        }
        if values.isEmpty {
            return String(
                localized: LocalizedStringResource(
            "0 of \(summary.total) complete.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        }
        return String(
            localized: LocalizedStringResource(
            "\(summary.completed) of \(summary.total) complete. \(values.joined(separator: ", "))",
            bundle: SkillsManagerLocalizationResources.bundle
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
            return String(localized: "Global shared target", bundle: SkillsManagerLocalizationResources.bundle)
        }
        let prefix = "agent:"
        guard scopeKey.hasPrefix(prefix) else {
            return String(localized: "Managed Copy target", bundle: SkillsManagerLocalizationResources.bundle)
        }
        let key = String(scopeKey.dropFirst(prefix.count))
        return SkillPlatform.allCases.first(where: { $0.storageKey == key })?.rawValue
            ?? String(localized: "Managed Agent target", bundle: SkillsManagerLocalizationResources.bundle)
    }
}

@MainActor extension SkillBatchUpdateResult {
    var title: String {
        switch self {
        case .updated: String(localized: "Updated", bundle: SkillsManagerLocalizationResources.bundle)
        case .upToDate: String(localized: "Up to date", bundle: SkillsManagerLocalizationResources.bundle)
        case .forked: String(localized: "Updated; local changes kept as Fork", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Conflict", bundle: SkillsManagerLocalizationResources.bundle)
        case .skipped: String(localized: "Skipped", bundle: SkillsManagerLocalizationResources.bundle)
        case .cancelled: String(localized: "Cancelled", bundle: SkillsManagerLocalizationResources.bundle)
        case .failed: String(localized: "Failed", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsAttention: String(localized: "Needs attention", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    var defaultDetail: String? {
        switch self {
        case .updated: String(localized: "The managed Skill and its distribution are current.", bundle: SkillsManagerLocalizationResources.bundle)
        case .upToDate: String(localized: "No update was required.", bundle: SkillsManagerLocalizationResources.bundle)
        case .forked: String(localized: "The parent Skill was updated and local changes are independent.", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Recheck after resolving local or remote changes.", bundle: SkillsManagerLocalizationResources.bundle)
        case .skipped: String(localized: "This available update was not selected.", bundle: SkillsManagerLocalizationResources.bundle)
        case .cancelled: String(localized: "No update was started for this Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .failed: String(localized: "The operation did not complete.", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsAttention: String(localized: "Review this Skill before trying again.", bundle: SkillsManagerLocalizationResources.bundle)
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
        case .discard: String(localized: "Discard local changes", bundle: SkillsManagerLocalizationResources.bundle)
        case .fork: String(localized: "Keep changes as a Fork", bundle: SkillsManagerLocalizationResources.bundle)
        case .cancel: String(localized: "Cancel this Skill update", bundle: SkillsManagerLocalizationResources.bundle)
    }
}
}
