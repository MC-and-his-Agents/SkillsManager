import Foundation

nonisolated func managedInstallResultPresentation(
    _ result: ManagedLocalImportResult
) -> (title: String, systemImage: String, message: String) {
    switch result.status {
    case .distributed:
        ("Installed and enabled", "checkmark.seal", "\(result.displayName) is ready.")
    case .noDistributionChanges:
        ("Installed", "checkmark.seal", "\(result.displayName) is managed.")
    case .managedUndistributed:
        (
            "Installed but not enabled",
            "exclamationmark.triangle",
            "\(result.displayName) is managed; resolve its distribution conflict from details."
        )
    case .managedDistributionIndeterminate:
        (
            "Distribution needs attention",
            "wrench.and.screwdriver",
            "\(result.displayName) is managed, but its Agent state must be confirmed."
        )
    case .managementIndeterminate:
        (
            "Install needs attention",
            "wrench.and.screwdriver",
            "Confirm or repair the managed library before retrying."
        )
    case .alreadyManaged:
        (
            "Already managed",
            "checkmark.circle",
            "Use the Skill details to change where \(result.displayName) is enabled."
        )
    case .updateRequired:
        (
            "Update required",
            "arrow.triangle.2.circlepath",
            "The remote source has different content or revision. No files were changed."
        )
    case .updated:
        (
            "Updated",
            "checkmark.seal",
            "\(result.displayName) was backed up and updated. Current Agent access was preserved."
        )
    case .updatedDistributionNeedsAttention:
        (
            "Updated; Agent state needs attention",
            "exclamationmark.triangle",
            "\(result.displayName) was updated and backed up. Refresh its distribution from details."
        )
    case .updateIndeterminate:
        (
            "Update needs confirmation",
            "wrench.and.screwdriver",
            "Confirm or repair the managed library before retrying this update."
        )
    }
}
