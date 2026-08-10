import Foundation

@MainActor
func localizedManagedInstallResultTitle(_ status: ManagedLocalImportResultStatus) -> String {
    switch status {
    case .distributed: String(localized: "Installed and enabled", bundle: .module)
    case .noDistributionChanges: String(localized: "Installed", bundle: .module)
    case .managedUndistributed: String(localized: "Installed but not enabled", bundle: .module)
    case .managedDistributionIndeterminate: String(localized: "Distribution needs attention", bundle: .module)
    case .managementIndeterminate: String(localized: "Install needs attention", bundle: .module)
    case .alreadyManaged: String(localized: "Already managed", bundle: .module)
    case .updateRequired: String(localized: "Update required", bundle: .module)
    case .updated: String(localized: "Updated", bundle: .module)
    case .updatedDistributionNeedsAttention: String(localized: "Updated; Agent state needs attention", bundle: .module)
    case .updateIndeterminate: String(localized: "Update needs confirmation", bundle: .module)
    }
}

@MainActor
func localizedManagedInstallResultMessage(_ result: ManagedLocalImportResult) -> String {
    let name = result.displayName
    switch result.status {
    case .distributed:
        return String(
            localized: LocalizedStringResource( "%@ is ready.",
            defaultValue: "\(name) is ready.",
            bundle: .module
        ))
    case .noDistributionChanges:
        return String(
            localized: LocalizedStringResource( "%@ is managed.",
            defaultValue: "\(name) is managed.",
            bundle: .module
        ))
    case .managedUndistributed:
        return String(
            localized: LocalizedStringResource( "%@ is managed; resolve its distribution conflict from details.",
            defaultValue: "\(name) is managed; resolve its distribution conflict from details.",
            bundle: .module
        ))
    case .managedDistributionIndeterminate:
        return String(
            localized: LocalizedStringResource( "%@ is managed, but its Agent state must be confirmed.",
            defaultValue: "\(name) is managed, but its Agent state must be confirmed.",
            bundle: .module
        ))
    case .managementIndeterminate:
        return String(localized: "Confirm or repair the managed library before retrying.", bundle: .module)
    case .alreadyManaged:
        return String(
            localized: LocalizedStringResource( "Use the Skill details to change where %@ is enabled.",
            defaultValue: "Use the Skill details to change where \(name) is enabled.",
            bundle: .module
        ))
    case .updateRequired:
        return String(localized: "The remote source has different content or revision. No files were changed.", bundle: .module)
    case .updated:
        return String(
            localized: LocalizedStringResource( "%@ was backed up and updated. Current Agent access was preserved.",
            defaultValue: "\(name) was backed up and updated. Current Agent access was preserved.",
            bundle: .module
        ))
    case .updatedDistributionNeedsAttention:
        return String(
            localized: LocalizedStringResource( "%@ was updated and backed up. Refresh its distribution from details.",
            defaultValue: "\(name) was updated and backed up. Refresh its distribution from details.",
            bundle: .module
        ))
    case .updateIndeterminate:
        return String(localized: "Confirm or repair the managed library before retrying this update.", bundle: .module)
    }
}

@MainActor
func localizedManagedLocalImportProblem(_ problem: ManagedLocalImportProblem) -> String {
    switch problem {
    case .emptyAgentSelection:
        String(localized: "Select at least one Agent.", bundle: .module)
    case .invalidCandidate:
        String(localized: "The selected Skill is no longer valid.", bundle: .module)
    case .operationInProgress:
        String(localized: "This import is already in progress.", bundle: .module)
    case .permissionDenied:
        String(localized: "Skills Manager does not have permission to import this Skill.", bundle: .module)
    case .previewBlocked:
        String(localized: "Resolve the distribution conflicts before importing.", bundle: .module)
    case .previewExpired:
        String(localized: "The import preview changed. Review it again before importing.", bundle: .module)
    case .createRolledBack:
        String(localized: "The Skill was not imported because the managed write was rolled back.", bundle: .module)
    case .updateRolledBack:
        String(localized: "The update was rolled back. The previous managed content is still available.", bundle: .module)
    case .needsRepair:
        String(localized: "The managed library requires repair before another import can start.", bundle: .module)
    case .sourceChanged:
        String(localized: "The selected Skill changed after validation. Choose it again.", bundle: .module)
    case .tokenExpired:
        String(localized: "The import preview expired. Prepare a new preview.", bundle: .module)
    case .providerConflict:
        String(localized: "The ClawHub source record conflicts with another managed Skill.", bundle: .module)
    case .providerAliasConflict:
        String(localized: "This skills.sh result is already linked to a different managed source.", bundle: .module)
    case .sourceUpdateUnsupportedLocalOrigins:
        String(localized: "This managed Skill also has local origins and cannot be safely updated from skills.sh.", bundle: .module)
    case .aliasLimitReached:
        String(localized: "This managed Skill has reached the Provider alias limit.", bundle: .module)
    case .failed(let detail):
        String(localized: LocalizedStringResource( "Import failed: %@", defaultValue: "Import failed: \(detail)", bundle: .module))
    case .updateFailed(let detail):
        String(localized: LocalizedStringResource( "Update failed: %@", defaultValue: "Update failed: \(detail)", bundle: .module))
    }
}

@MainActor func managedInstallResultPresentation(
    _ result: ManagedLocalImportResult
) -> (title: String, systemImage: String, message: String) {
    (
        localizedManagedInstallResultTitle(result.status),
        result.status.systemImage,
        localizedManagedInstallResultMessage(result)
    )
}

private extension ManagedLocalImportResultStatus {
    var systemImage: String {
        switch self {
        case .distributed, .noDistributionChanges, .updated: "checkmark.seal"
        case .managedUndistributed, .updatedDistributionNeedsAttention: "exclamationmark.triangle"
        case .managedDistributionIndeterminate, .managementIndeterminate, .updateIndeterminate:
            "wrench.and.screwdriver"
        case .alreadyManaged: "checkmark.circle"
        case .updateRequired: "arrow.triangle.2.circlepath"
        }
    }
}
