import Foundation
import SwiftUI

extension SkillDiscoveryStatus {
    var displayName: String {
        switch self {
        case .managed: "Managed"
        case .claimable: "Ready to claim"
        case .unmanaged: "Unmanaged"
        case .conflict: "Conflict"
        case .permissionDenied: "Permission denied"
        case .damaged: "Damaged"
        }
    }

    var systemImage: String {
        switch self {
        case .managed: "checkmark.seal"
        case .claimable: "link.badge.plus"
        case .unmanaged: "tray.and.arrow.down"
        case .conflict: "exclamationmark.triangle"
        case .permissionDenied: "lock.trianglebadge.exclamationmark"
        case .damaged: "doc.badge.ellipsis"
        }
    }

    var tint: Color {
        switch self {
        case .managed: .green
        case .claimable: .blue
        case .unmanaged: .accentColor
        case .conflict: SkillStatusPalette.warning
        case .permissionDenied, .damaged: SkillStatusPalette.blocking
        }
    }
}

@MainActor extension SkillDiscoveryStatus {
    var localizedDisplayName: String {
        switch self {
        case .managed: String(localized: "Managed", bundle: SkillsManagerLocalizationResources.bundle)
        case .claimable: String(localized: "Ready to claim", bundle: SkillsManagerLocalizationResources.bundle)
        case .unmanaged: String(localized: "Unmanaged", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Conflict", bundle: SkillsManagerLocalizationResources.bundle)
        case .permissionDenied: String(localized: "Permission denied", bundle: SkillsManagerLocalizationResources.bundle)
        case .damaged: String(localized: "Damaged", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}

extension SkillDiscoveryReason {
    nonisolated var displayName: String {
        switch self {
        case .rootPermissionDenied: "The scan root cannot be read."
        case .rootChanged: "The scan root changed while it was being inspected."
        case .rootUnsupportedType: "The scan root is not a directory or supported link."
        case .rootReadFailed: "The scan root could not be read."
        case .unknownSymlink: "The Skill uses a symbolic link that cannot be trusted."
        case .symbolicLinkTargetUnavailable: "The Skill link target is unavailable."
        case .symbolicLinkTargetUnsupported: "The Skill link target is not a directory."
        case .candidatePermissionDenied: "The Skill folder cannot be read."
        case .sourceChanged: "The Skill changed while it was being inspected."
        case .missingSkillManifest: "SKILL.md is missing."
        case .containerDirectory: "This folder contains Skill subdirectories."
        case .invalidSkillManifest: "SKILL.md is not valid UTF-8."
        case .unsupportedEntryType: "The Skill contains an unsupported file type."
        case .unsafeContent: "The Skill contains an unsafe path or link."
        case .resourceLimitExceeded: "The Skill exceeds the safe import limits."
        case .candidateReadFailed: "The Skill content could not be read."
        case .ambiguousLocalAssociation: "This location is linked to more than one managed Skill."
        case .localAssociationDrift: "This location no longer matches its managed Skill."
        case .ambiguousSource: "The source metadata matches more than one managed Skill."
        case .ambiguousFingerprint: "The content matches more than one managed Skill."
        case .evidenceConflict: "The source and content point to different managed Skills."
        case .scopeSlugConflict: "More than one Skill uses this name in the same scope."
        }
    }
}

@MainActor extension SkillDiscoveryReason {
    var localizedDisplayName: String {
        switch self {
        case .rootPermissionDenied: String(localized: "The scan root cannot be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootChanged: String(localized: "The scan root changed while it was being inspected.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootUnsupportedType: String(localized: "The scan root is not a directory or supported link.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootReadFailed: String(localized: "The scan root could not be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unknownSymlink: String(localized: "The Skill uses a symbolic link that cannot be trusted.", bundle: SkillsManagerLocalizationResources.bundle)
        case .symbolicLinkTargetUnavailable: String(localized: "The Skill link target is unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .symbolicLinkTargetUnsupported: String(localized: "The Skill link target is not a directory.", bundle: SkillsManagerLocalizationResources.bundle)
        case .candidatePermissionDenied: String(localized: "The Skill folder cannot be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .sourceChanged: String(localized: "The Skill changed while it was being inspected.", bundle: SkillsManagerLocalizationResources.bundle)
        case .missingSkillManifest: String(localized: "SKILL.md is missing.", bundle: SkillsManagerLocalizationResources.bundle)
        case .containerDirectory: String(localized: "This folder contains Skill subdirectories.", bundle: SkillsManagerLocalizationResources.bundle)
        case .invalidSkillManifest: String(localized: "SKILL.md is not valid UTF-8.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unsupportedEntryType: String(localized: "The Skill contains an unsupported file type.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unsafeContent: String(localized: "The Skill contains an unsafe path or link.", bundle: SkillsManagerLocalizationResources.bundle)
        case .resourceLimitExceeded: String(localized: "The Skill exceeds the safe import limits.", bundle: SkillsManagerLocalizationResources.bundle)
        case .candidateReadFailed: String(localized: "The Skill content could not be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousLocalAssociation: String(localized: "This location is linked to more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .localAssociationDrift: String(localized: "This location no longer matches its managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousSource: String(localized: "The source metadata matches more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousFingerprint: String(localized: "The content matches more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .evidenceConflict: String(localized: "The source and content point to different managed Skills.", bundle: SkillsManagerLocalizationResources.bundle)
        case .scopeSlugConflict: String(localized: "More than one Skill uses this name in the same scope.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}

extension SkillDiscoveryScope {
    var displayName: String {
        switch kind {
        case .global:
            "Global"
        case .agent:
            [adapterDisplayName, pathVariant].compactMap { $0 }.joined(separator: " · ")
        case .custom:
            ["Custom", adapterDisplayName, pathVariant].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var adapterDisplayName: String? {
        guard let adapterCode else { return nil }
        return SkillPlatform.allCases.first { $0.storageKey == adapterCode }?.rawValue
            ?? adapterCode
    }
}

@MainActor extension SkillDiscoveryScope {
    var localizedDisplayName: String {
        let adapter = adapterDisplayName
        switch kind {
        case .global:
            return String(localized: "Global", bundle: SkillsManagerLocalizationResources.bundle)
        case .agent:
            let values = [adapter, pathVariant].compactMap { $0 }
            return values.dropFirst().reduce(values.first ?? "") { partial, value in
                String(localized: LocalizedStringResource(
            "\(partial) · \(value)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            }
        case .custom:
            let values = [String(localized: "Custom", bundle: SkillsManagerLocalizationResources.bundle), adapter, pathVariant]
                .compactMap { $0 }
            return values.dropFirst().reduce(values.first ?? "") { partial, value in
                String(localized: LocalizedStringResource(
            "\(partial) · \(value)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            }
        }
    }
}

extension SkillDiscoveryObservation {
    var displayName: String {
        SkillContentLocator(rawRelativeLocator)?.leafName ?? relativeLocator
    }

    var scopeSummary: String {
        Array(Set(scopes.map(\.displayName))).sorted().joined(separator: ", ")
    }

    var sourceSummary: String {
        if let matchedSourceKey {
            let suffix = matchedSourceKey.subpath.isEmpty ? "" : " · \(matchedSourceKey.subpath)"
            return matchedSourceKey.repositoryURL + suffix
        }
        guard !providerAliases.isEmpty else { return "No source metadata" }
        return providerAliases
            .map { "\($0.provider): \($0.identifier)" }
            .sorted()
            .joined(separator: ", ")
    }

    var fingerprintSummary: String {
        guard let fingerprint else { return "Unavailable" }
        let prefix = fingerprint.digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "SHA-256 \(prefix)…"
    }

    var reasonSummary: String {
        reason?.displayName ?? "No issue detected."
    }
}

@MainActor extension SkillDiscoveryObservation {
    var localizedSourceSummary: String {
        if let matchedSourceKey {
            let suffix = matchedSourceKey.subpath.isEmpty ? "" : " · \(matchedSourceKey.subpath)"
            return matchedSourceKey.repositoryURL + suffix
        }
        guard !providerAliases.isEmpty else {
            return String(localized: "No source metadata", bundle: SkillsManagerLocalizationResources.bundle)
        }
        return providerAliases
            .map { "\(localizedProviderName($0.provider)): \($0.identifier)" }
            .sorted()
            .joined(separator: ", ")
    }

    var localizedFingerprintSummary: String {
        guard let fingerprint else {
            return String(localized: "Unavailable", bundle: SkillsManagerLocalizationResources.bundle)
        }
        let prefix = fingerprint.digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return String(localized: LocalizedStringResource(
            "SHA-256 \(prefix)…",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }

    var localizedReasonSummary: String {
        reason?.localizedDisplayName
            ?? String(localized: "No issue detected.", bundle: SkillsManagerLocalizationResources.bundle)
    }

    private func localizedProviderName(_ provider: String) -> String {
        switch provider {
        case "ClawHub": return String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
        case "skills.sh": return String(localized: "skills.sh", bundle: SkillsManagerLocalizationResources.bundle)
        case "GitHub": return String(localized: "GitHub", bundle: SkillsManagerLocalizationResources.bundle)
        default: return provider
        }
    }
}

extension SkillDiscoveryRootDiagnostic {
    var accessibilitySummary: String {
        "\(root.scope.displayName), \(root.url.path), \(reason.displayName)"
    }
}

@MainActor extension SkillDiscoveryRootDiagnostic {
    var localizedAccessibilitySummary: String {
        let scope = root.scope.localizedDisplayName
        let reason = reason.localizedDisplayName
        return String(localized: LocalizedStringResource(
            "\(scope), \(root.url.path), \(reason)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }
}
