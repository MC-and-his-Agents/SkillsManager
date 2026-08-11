import Foundation

@MainActor
func localizedManagedInstallResultTitle(_ status: ManagedLocalImportResultStatus) -> String {
    switch status {
    case .distributed: String(localized: "Installed and enabled", bundle: SkillsManagerLocalizationResources.bundle)
    case .noDistributionChanges: String(localized: "Installed", bundle: SkillsManagerLocalizationResources.bundle)
    case .managedUndistributed: String(localized: "Installed but not enabled", bundle: SkillsManagerLocalizationResources.bundle)
    case .managedDistributionIndeterminate: String(localized: "Distribution needs attention", bundle: SkillsManagerLocalizationResources.bundle)
    case .managementIndeterminate: String(localized: "Install needs attention", bundle: SkillsManagerLocalizationResources.bundle)
    case .alreadyManaged: String(localized: "Already managed", bundle: SkillsManagerLocalizationResources.bundle)
    case .updateRequired: String(localized: "Update required", bundle: SkillsManagerLocalizationResources.bundle)
    case .updated: String(localized: "Updated", bundle: SkillsManagerLocalizationResources.bundle)
    case .updatedDistributionNeedsAttention: String(localized: "Updated; Agent state needs attention", bundle: SkillsManagerLocalizationResources.bundle)
    case .updateIndeterminate: String(localized: "Update needs confirmation", bundle: SkillsManagerLocalizationResources.bundle)
    }
}

@MainActor
func localizedManagedInstallResultMessage(_ result: ManagedLocalImportResult) -> String {
    let name = result.displayName
    switch result.status {
    case .distributed:
        return String(
            localized: LocalizedStringResource(
            "\(name) is ready.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .noDistributionChanges:
        return String(
            localized: LocalizedStringResource(
            "\(name) is managed.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .managedUndistributed:
        return String(
            localized: LocalizedStringResource(
            "\(name) is managed; resolve its distribution conflict from details.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .managedDistributionIndeterminate:
        return String(
            localized: LocalizedStringResource(
            "\(name) is managed, but its Agent state must be confirmed.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .managementIndeterminate:
        return String(localized: "Confirm or repair the managed library before retrying.", bundle: SkillsManagerLocalizationResources.bundle)
    case .alreadyManaged:
        return String(
            localized: LocalizedStringResource(
            "Use the Skill details to change where \(name) is enabled.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .updateRequired:
        return String(localized: "The remote source has different content or revision. No files were changed.", bundle: SkillsManagerLocalizationResources.bundle)
    case .updated:
        return String(
            localized: LocalizedStringResource(
            "\(name) was backed up and updated. Current Agent access was preserved.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .updatedDistributionNeedsAttention:
        return String(
            localized: LocalizedStringResource(
            "\(name) was updated and backed up. Refresh its distribution from details.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .updateIndeterminate:
        return String(localized: "Confirm or repair the managed library before retrying this update.", bundle: SkillsManagerLocalizationResources.bundle)
    }
}

@MainActor
func localizedManagedLocalImportProblem(_ problem: ManagedLocalImportProblem) -> String {
    switch problem {
    case .emptyAgentSelection:
        String(localized: "Select at least one Agent.", bundle: SkillsManagerLocalizationResources.bundle)
    case .invalidCandidate:
        String(localized: "The selected Skill is no longer valid.", bundle: SkillsManagerLocalizationResources.bundle)
    case .operationInProgress:
        String(localized: "This import is already in progress.", bundle: SkillsManagerLocalizationResources.bundle)
    case .permissionDenied:
        String(localized: "Skills Manager does not have permission to import this Skill.", bundle: SkillsManagerLocalizationResources.bundle)
    case .previewBlocked:
        String(localized: "Resolve the distribution conflicts before importing.", bundle: SkillsManagerLocalizationResources.bundle)
    case .previewExpired:
        String(localized: "The import preview changed. Review it again before importing.", bundle: SkillsManagerLocalizationResources.bundle)
    case .createRolledBack:
        String(localized: "The Skill was not imported because the managed write was rolled back.", bundle: SkillsManagerLocalizationResources.bundle)
    case .updateRolledBack:
        String(localized: "The update was rolled back. The previous managed content is still available.", bundle: SkillsManagerLocalizationResources.bundle)
    case .needsRepair:
        String(localized: "The managed library requires repair before another import can start.", bundle: SkillsManagerLocalizationResources.bundle)
    case .sourceChanged:
        String(localized: "The selected Skill changed after validation. Choose it again.", bundle: SkillsManagerLocalizationResources.bundle)
    case .tokenExpired:
        String(localized: "The import preview expired. Prepare a new preview.", bundle: SkillsManagerLocalizationResources.bundle)
    case .providerConflict:
        String(localized: "The ClawHub source record conflicts with another managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
    case .providerAliasConflict:
        String(localized: "This skills.sh result is already linked to a different managed source.", bundle: SkillsManagerLocalizationResources.bundle)
    case .sourceUpdateUnsupportedLocalOrigins:
        String(localized: "This managed Skill also has local origins and cannot be safely updated from skills.sh.", bundle: SkillsManagerLocalizationResources.bundle)
    case .aliasLimitReached:
        String(localized: "This managed Skill has reached the Provider alias limit.", bundle: SkillsManagerLocalizationResources.bundle)
    case .failed(let detail):
        String(localized: LocalizedStringResource(
            "Import failed: \(detail)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .updateFailed(let detail):
        String(localized: LocalizedStringResource(
            "Update failed: \(detail)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }
}

@MainActor
func localizedManagedSkillImportError(_ error: ManagedSkillImportError) -> String {
    switch error {
    case .actionNotAllowed:
        String(localized: "This action is no longer available.", bundle: SkillsManagerLocalizationResources.bundle)
    case .conflict:
        String(localized: "The source now conflicts with another managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
    case .invalidObservation:
        String(localized: "The discovery result is no longer valid.", bundle: SkillsManagerLocalizationResources.bundle)
    case .sourceChanged:
        String(localized: "The source changed after preview.", bundle: SkillsManagerLocalizationResources.bundle)
    case .tokenExpired:
        String(localized: "The preview expired.", bundle: SkillsManagerLocalizationResources.bundle)
    }
}

@MainActor
func localizedSkillPackageError(_ error: SkillPackageError) -> String {
    switch error {
    case .unsupportedRoot:
        String(localized: "The selected item must be a regular folder, not a symbolic link.", bundle: SkillsManagerLocalizationResources.bundle)
    case .missingManifest:
        String(localized: "The selected item doesn’t contain a SKILL.md file.", bundle: SkillsManagerLocalizationResources.bundle)
    case .ambiguousRoots:
        String(localized: "The selected item contains more than one Skill folder.", bundle: SkillsManagerLocalizationResources.bundle)
    case .unsafeManifest(let path):
        String(localized: LocalizedStringResource(
            "The Skill manifest must be a regular file: \(path)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }
}

@MainActor
func localizedSkillImportValidationError(_ error: SkillImportValidationError) -> String {
    switch error {
    case .archiveRejected(let reason):
        String(localized: LocalizedStringResource(
            "The zip archive is unsafe or invalid: \(reason)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    case .contentRejected(let reason):
        String(localized: LocalizedStringResource(
            "The Skill contents are unsafe or invalid: \(reason)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }
}

@MainActor
func localizedKnownRemoteError(_ error: Error) -> String? {
    if let error = error as? SkillsShGitHubSourceError {
        return switch error {
        case .invalidSource:
            String(localized: "The skills.sh GitHub source is invalid.", bundle: SkillsManagerLocalizationResources.bundle)
        case .repositoryUnavailable:
            String(localized: "The GitHub repository is unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .providerUnavailable:
            String(localized: "GitHub is temporarily unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rateLimited:
            String(localized: "GitHub rate limited this request.", bundle: SkillsManagerLocalizationResources.bundle)
        case .timeout:
            String(localized: "GitHub did not respond in time.", bundle: SkillsManagerLocalizationResources.bundle)
        case .offline:
            String(localized: "GitHub is unavailable while the network is offline.", bundle: SkillsManagerLocalizationResources.bundle)
        case .network:
            String(localized: "GitHub could not be reached.", bundle: SkillsManagerLocalizationResources.bundle)
        case .cancelled:
            String(localized: "The GitHub source request was cancelled.", bundle: SkillsManagerLocalizationResources.bundle)
        case .responseTooLarge:
            String(localized: "GitHub returned more data than can be handled safely.", bundle: SkillsManagerLocalizationResources.bundle)
        case .contractChanged:
            String(localized: "The GitHub source response did not match the expected contract.", bundle: SkillsManagerLocalizationResources.bundle)
        case .treeTruncated:
            String(localized: "The GitHub repository tree is too large to resolve safely.", bundle: SkillsManagerLocalizationResources.bundle)
        case .noUniqueSkillMatch:
            String(localized: "The GitHub source does not identify exactly one Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
    if let error = error as? SkillsShSearchError {
        return switch error {
        case .invalidRequest:
            String(localized: "The skills.sh search request is invalid.", bundle: SkillsManagerLocalizationResources.bundle)
        case .timeout:
            String(localized: "skills.sh did not respond in time.", bundle: SkillsManagerLocalizationResources.bundle)
        case .offline:
            String(localized: "skills.sh is unavailable while the network is offline.", bundle: SkillsManagerLocalizationResources.bundle)
        case .network:
            String(localized: "skills.sh could not be reached.", bundle: SkillsManagerLocalizationResources.bundle)
        case .redirectRejected:
            String(localized: "skills.sh redirected the search endpoint.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                String(localized: LocalizedStringResource(
                    "skills.sh rate limited this request. Try again in \(retryAfterSeconds) seconds.",
                    bundle: SkillsManagerLocalizationResources.bundle
                ))
            } else {
                String(localized: "skills.sh rate limited this request.", bundle: SkillsManagerLocalizationResources.bundle)
            }
        case .providerUnavailable:
            String(localized: "skills.sh is temporarily unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .responseTooLarge:
            String(localized: "skills.sh returned more search data than can be handled safely.", bundle: SkillsManagerLocalizationResources.bundle)
        case .contractChanged:
            String(localized: "The skills.sh search interface has changed.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
    if let error = error as? RemoteSkillClientError {
        return switch error {
        case .rateLimited:
            String(localized: "ClawHub rate limited this request.", bundle: SkillsManagerLocalizationResources.bundle)
        case .providerUnavailable:
            String(localized: "ClawHub is temporarily unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .invalidResponse:
            String(localized: "ClawHub returned an invalid response.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
    return nil
}

@MainActor
func localizedManagedInstallError(_ error: Error) -> String {
    if let error = error as? ManagedLocalImportProblem {
        return localizedManagedLocalImportProblem(error)
    }
    if let error = error as? SkillPackageError {
        return localizedSkillPackageError(error)
    }
    if let error = error as? SkillImportValidationError {
        return localizedSkillImportValidationError(error)
    }
    if let error = error as? ManagedSkillImportError {
        return localizedManagedSkillImportError(error)
    }
    return localizedKnownRemoteError(error) ?? error.localizedDescription
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
