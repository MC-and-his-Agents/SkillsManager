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
            localized: LocalizedStringResource(
            "\(name) is ready.",
            bundle: .module
        ))
    case .noDistributionChanges:
        return String(
            localized: LocalizedStringResource(
            "\(name) is managed.",
            bundle: .module
        ))
    case .managedUndistributed:
        return String(
            localized: LocalizedStringResource(
            "\(name) is managed; resolve its distribution conflict from details.",
            bundle: .module
        ))
    case .managedDistributionIndeterminate:
        return String(
            localized: LocalizedStringResource(
            "\(name) is managed, but its Agent state must be confirmed.",
            bundle: .module
        ))
    case .managementIndeterminate:
        return String(localized: "Confirm or repair the managed library before retrying.", bundle: .module)
    case .alreadyManaged:
        return String(
            localized: LocalizedStringResource(
            "Use the Skill details to change where \(name) is enabled.",
            bundle: .module
        ))
    case .updateRequired:
        return String(localized: "The remote source has different content or revision. No files were changed.", bundle: .module)
    case .updated:
        return String(
            localized: LocalizedStringResource(
            "\(name) was backed up and updated. Current Agent access was preserved.",
            bundle: .module
        ))
    case .updatedDistributionNeedsAttention:
        return String(
            localized: LocalizedStringResource(
            "\(name) was updated and backed up. Refresh its distribution from details.",
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
        String(localized: LocalizedStringResource(
            "Import failed: \(detail)",
            bundle: .module
        ))
    case .updateFailed(let detail):
        String(localized: LocalizedStringResource(
            "Update failed: \(detail)",
            bundle: .module
        ))
    }
}

@MainActor
func localizedManagedSkillImportError(_ error: ManagedSkillImportError) -> String {
    switch error {
    case .actionNotAllowed:
        String(localized: "This action is no longer available.", bundle: .module)
    case .conflict:
        String(localized: "The source now conflicts with another managed Skill.", bundle: .module)
    case .invalidObservation:
        String(localized: "The discovery result is no longer valid.", bundle: .module)
    case .sourceChanged:
        String(localized: "The source changed after preview.", bundle: .module)
    case .tokenExpired:
        String(localized: "The preview expired.", bundle: .module)
    }
}

@MainActor
func localizedSkillPackageError(_ error: SkillPackageError) -> String {
    switch error {
    case .unsupportedRoot:
        String(localized: "The selected item must be a regular folder, not a symbolic link.", bundle: .module)
    case .missingManifest:
        String(localized: "The selected item doesn’t contain a SKILL.md file.", bundle: .module)
    case .ambiguousRoots:
        String(localized: "The selected item contains more than one Skill folder.", bundle: .module)
    case .unsafeManifest(let path):
        String(localized: LocalizedStringResource(
            "The Skill manifest must be a regular file: \(path)",
            bundle: .module
        ))
    }
}

@MainActor
func localizedSkillImportValidationError(_ error: SkillImportValidationError) -> String {
    switch error {
    case .archiveRejected(let reason):
        String(localized: LocalizedStringResource(
            "The zip archive is unsafe or invalid: \(reason)",
            bundle: .module
        ))
    case .contentRejected(let reason):
        String(localized: LocalizedStringResource(
            "The Skill contents are unsafe or invalid: \(reason)",
            bundle: .module
        ))
    }
}

@MainActor
func localizedKnownRemoteError(_ error: Error) -> String? {
    if let error = error as? SkillsShGitHubSourceError {
        return switch error {
        case .invalidSource:
            String(localized: "The skills.sh GitHub source is invalid.", bundle: .module)
        case .repositoryUnavailable:
            String(localized: "The GitHub repository is unavailable.", bundle: .module)
        case .providerUnavailable:
            String(localized: "GitHub is temporarily unavailable.", bundle: .module)
        case .rateLimited:
            String(localized: "GitHub rate limited this request.", bundle: .module)
        case .timeout:
            String(localized: "GitHub did not respond in time.", bundle: .module)
        case .offline:
            String(localized: "GitHub is unavailable while the network is offline.", bundle: .module)
        case .network:
            String(localized: "GitHub could not be reached.", bundle: .module)
        case .cancelled:
            String(localized: "The GitHub source request was cancelled.", bundle: .module)
        case .responseTooLarge:
            String(localized: "GitHub returned more data than can be handled safely.", bundle: .module)
        case .contractChanged:
            String(localized: "The GitHub source response did not match the expected contract.", bundle: .module)
        case .treeTruncated:
            String(localized: "The GitHub repository tree is too large to resolve safely.", bundle: .module)
        case .noUniqueSkillMatch:
            String(localized: "The GitHub source does not identify exactly one Skill.", bundle: .module)
        }
    }
    if let error = error as? SkillsShSearchError {
        return switch error {
        case .invalidRequest:
            String(localized: "The skills.sh search request is invalid.", bundle: .module)
        case .timeout:
            String(localized: "skills.sh did not respond in time.", bundle: .module)
        case .offline:
            String(localized: "skills.sh is unavailable while the network is offline.", bundle: .module)
        case .network:
            String(localized: "skills.sh could not be reached.", bundle: .module)
        case .redirectRejected:
            String(localized: "skills.sh redirected the search endpoint.", bundle: .module)
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                String(localized: LocalizedStringResource(
                    "skills.sh rate limited this request. Try again in \(retryAfterSeconds) seconds.",
                    bundle: .module
                ))
            } else {
                String(localized: "skills.sh rate limited this request.", bundle: .module)
            }
        case .providerUnavailable:
            String(localized: "skills.sh is temporarily unavailable.", bundle: .module)
        case .responseTooLarge:
            String(localized: "skills.sh returned more search data than can be handled safely.", bundle: .module)
        case .contractChanged:
            String(localized: "The skills.sh search interface has changed.", bundle: .module)
        }
    }
    if let error = error as? RemoteSkillClientError {
        return switch error {
        case .rateLimited:
            String(localized: "ClawHub rate limited this request.", bundle: .module)
        case .providerUnavailable:
            String(localized: "ClawHub is temporarily unavailable.", bundle: .module)
        case .invalidResponse:
            String(localized: "ClawHub returned an invalid response.", bundle: .module)
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
