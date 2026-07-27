import Foundation

extension SkillLifecycleViewModel {
    enum Problem: Equatable {
        case previewExpired
        case conflict
        case permissionDenied
        case unavailable
        case operationInProgress
        case needsRepair
        case backupCorrupt
        case rolledBack
        case restoredUndistributed
        case operationDidNotComplete
        case failed(String)

        var message: String {
            switch self {
            case .previewExpired:
                "The preview expired because the managed state changed. Review it again."
            case .conflict:
                "The Skill or its distribution changed. Refresh before trying again."
            case .permissionDenied:
                "Skills Manager does not have permission to complete this operation."
            case .unavailable:
                "The Skill lifecycle service is unavailable."
            case .operationInProgress:
                "A deletion operation is still in progress."
            case .needsRepair:
                "This deletion or backup requires repair before another change can start."
            case .backupCorrupt:
                "The backup is missing, changed, or corrupt and cannot be restored."
            case .rolledBack:
                "Deletion did not complete. The active Skill was restored to its prior state."
            case .restoredUndistributed:
                "The Skill was restored, but its original Agent targets could not be restored."
            case .operationDidNotComplete:
                "The operation did not reach a successful terminal state."
            case .failed(let message):
                message
            }
        }
    }

    static func problem(for error: Error) -> Problem {
        guard let error = error as? SkillDeletionError else {
            return .failed(error.localizedDescription)
        }
        return switch error {
        case .skillNotFound, .conflict:
            .conflict
        case .previewExpired:
            .previewExpired
        case .operationInProgress:
            .operationInProgress
        case .needsRepair:
            .needsRepair
        case .backupCorrupt:
            .backupCorrupt
        case .permissionDenied:
            .permissionDenied
        case .unavailable:
            .unavailable
        }
    }
}

extension SkillDeletionStatus {
    var displayName: String {
        switch self {
        case .ready: "Ready"
        case .operationInProgress: "Operation in progress"
        case .needsRepair: "Needs repair"
        case .completed: "Completed"
        case .cleanupPending: "Cleanup pending"
        case .rolledBack: "Rolled back"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.shield"
        case .operationInProgress: "clock.arrow.circlepath"
        case .needsRepair: "wrench.and.screwdriver"
        case .completed: "checkmark.circle.fill"
        case .cleanupPending: "hourglass"
        case .rolledBack: "arrow.uturn.backward.circle"
        }
    }
}

extension SkillBackupCatalogAvailability {
    var displayName: String {
        switch self {
        case .available: "Available"
        case .preparing: "Preparing"
        case .pruning: "Cleaning up"
        case .needsRepair: "Needs repair"
        case .corrupt: "Corrupt"
        case .permissionDenied: "Permission required"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .available: "archivebox"
        case .preparing, .pruning: "clock.arrow.circlepath"
        case .needsRepair: "wrench.and.screwdriver"
        case .corrupt: "exclamationmark.octagon"
        case .permissionDenied: "lock.trianglebadge.exclamationmark"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

extension SkillRestoreStatus {
    var displayName: String {
        switch self {
        case .ready: "Ready to restore"
        case .noOp: "Matching Skill already exists"
        case .completed: "Restored"
        case .restoredUndistributed: "Restored without Agent targets"
        }
    }
}

extension SkillContentFingerprint {
    var shortDisplayName: String {
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)…"
    }
}

extension SkillContentSnapshot.Statistics {
    var byteCountDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalByteCount), countStyle: .file)
    }
}

extension SkillBackupCatalogItem {
    var createdAt: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1_000)
    }
}

nonisolated func skillRestoreWarningDescription(_ warning: String) -> String {
    if warning == "distribution_conflict" {
        return "The original Agent targets conflict with current managed content."
    }
    if warning == "source_conflict" {
        return "The original repository identity is already used by another Skill."
    }
    if warning == "source_unavailable" {
        return "The original source could not be restored."
    }
    if warning.hasPrefix("alias_conflict:") {
        return "A provider alias is already used and was not restored."
    }
    if warning.hasPrefix("origin_conflict:") {
        return "A local origin is already used and was not restored."
    }
    return warning
}
