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
        return localizedInstallTemplate(
            LocalizedStringResource(
                "%arg is ready.",
                defaultValue: "%arg is ready.",
                bundle: .module
            ),
            arguments: [name]
        )
    case .noDistributionChanges:
        return localizedInstallTemplate(
            LocalizedStringResource(
                "%arg is managed.",
                defaultValue: "%arg is managed.",
                bundle: .module
            ),
            arguments: [name]
        )
    case .managedUndistributed:
        return localizedInstallTemplate(
            LocalizedStringResource(
                "%arg is managed; resolve its distribution conflict from details.",
                defaultValue: "%arg is managed; resolve its distribution conflict from details.",
                bundle: .module
            ),
            arguments: [name]
        )
    case .managedDistributionIndeterminate:
        return localizedInstallTemplate(
            LocalizedStringResource(
                "%arg is managed, but its Agent state must be confirmed.",
                defaultValue: "%arg is managed, but its Agent state must be confirmed.",
                bundle: .module
            ),
            arguments: [name]
        )
    case .managementIndeterminate:
        return String(localized: "Confirm or repair the managed library before retrying.", bundle: .module)
    case .alreadyManaged:
        return localizedInstallTemplate(
            LocalizedStringResource(
                "Use the Skill details to change where %arg is enabled.",
                defaultValue: "Use the Skill details to change where %arg is enabled.",
                bundle: .module
            ),
            arguments: [name]
        )
    case .updateRequired:
        return String(localized: "The remote source has different content or revision. No files were changed.", bundle: .module)
    case .updated:
        return localizedInstallTemplate(
            LocalizedStringResource(
                "%arg was backed up and updated. Current Agent access was preserved.",
                defaultValue: "%arg was backed up and updated. Current Agent access was preserved.",
                bundle: .module
            ),
            arguments: [name]
        )
    case .updatedDistributionNeedsAttention:
        return localizedInstallTemplate(
            LocalizedStringResource(
                "%arg was updated and backed up. Refresh its distribution from details.",
                defaultValue: "%arg was updated and backed up. Refresh its distribution from details.",
                bundle: .module
            ),
            arguments: [name]
        )
    case .updateIndeterminate:
        return String(localized: "Confirm or repair the managed library before retrying this update.", bundle: .module)
    }
}

@MainActor
private func localizedInstallTemplate(
    _ resource: LocalizedStringResource,
    arguments: [String]
) -> String {
    var value = String(localized: resource)
    for argument in arguments {
        guard let range = value.range(of: "%arg") else { break }
        value.replaceSubrange(range, with: argument)
    }
    return value
}

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
