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
        case .conflict: .orange
        case .permissionDenied, .damaged: .red
        }
    }
}

extension SkillDiscoveryReason {
    var displayName: String {
        switch self {
        case .rootPermissionDenied: "The scan root cannot be read."
        case .rootChanged: "The scan root changed while it was being inspected."
        case .rootUnsupportedType: "The scan root is not a directory or supported link."
        case .rootReadFailed: "The scan root could not be read."
        case .unknownSymlink: "The Skill uses a symbolic link that cannot be trusted."
        case .candidatePermissionDenied: "The Skill folder cannot be read."
        case .sourceChanged: "The Skill changed while it was being inspected."
        case .missingSkillManifest: "SKILL.md is missing."
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

extension SkillDiscoveryObservation {
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

extension SkillDiscoveryRootDiagnostic {
    var accessibilitySummary: String {
        "\(root.scope.displayName), \(root.url.path), \(reason.displayName)"
    }
}
