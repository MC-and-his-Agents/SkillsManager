import Foundation
import Observation

nonisolated enum LibraryRuntimePhase: String, Sendable {
    case classifying
    case creatingManagementRoot
    case acquiringOwnership
    case bootstrapping
    case openingDatabase
    case recovering
    case migratingLegacy
    case checking
    case running
}

nonisolated enum LibraryRuntimeReadiness: String, Sendable {
    case ready
    case blocked
}

nonisolated enum LibraryDiagnosticSeverity: String, Sendable {
    case warning
    case error
    case critical

    fileprivate var rank: Int {
        switch self {
        case .warning: 0
        case .error: 1
        case .critical: 2
        }
    }
}

nonisolated enum LibraryDiagnosticRetryability: String, Sendable {
    case retryable
    case notRetryable
}

nonisolated enum LibraryDiagnosticDataPreservation: String, Sendable {
    case preserved
    case uncertain
}

nonisolated enum LibraryDiagnosticSubjectKind: String, Sendable {
    case library
    case database
    case ssot
    case skill
    case journal
    case cleanup
    case legacy
    case bootstrap
}

nonisolated enum LibraryDiagnosticCode: String, Sendable {
    case databaseMissing
    case ssotMissing
    case schemaMismatch
    case legacyMigrationBlocked
    case journalNeedsRepair
    case orphanSSOTDirectory
    case unknownSSOTEntry
    case databaseSkillMissingDirectory
    case contentFingerprintDrift
    case rootIdentityChanged
    case permissionDenied
    case databaseBusy
    case cleanupDebt
    case legacyArchiveChanged
    case unrecoverable
}

nonisolated struct LibraryRuntimeDiagnostic: Equatable, Sendable {
    let code: LibraryDiagnosticCode
    let severity: LibraryDiagnosticSeverity
    let subjectKind: LibraryDiagnosticSubjectKind
    let subjectID: String
    let retryability: LibraryDiagnosticRetryability
    let dataPreservation: LibraryDiagnosticDataPreservation
    let recommendedActionCode: String
    let blocking: Bool

    static func make(
        _ code: LibraryDiagnosticCode,
        subjectKind: LibraryDiagnosticSubjectKind,
        subjectID: String
    ) -> Self {
        let policy: (
            LibraryDiagnosticSeverity,
            Bool,
            LibraryDiagnosticRetryability,
            LibraryDiagnosticDataPreservation,
            String
        ) = switch code {
        case .databaseMissing:
            (.error, true, .notRetryable, .uncertain, "restoreDatabase")
        case .ssotMissing:
            (.error, true, .notRetryable, .uncertain, "restoreSSOT")
        case .schemaMismatch:
            (.error, true, .notRetryable, .preserved, "upgradeApplication")
        case .legacyMigrationBlocked:
            (.error, true, .retryable, .preserved, "retryLegacyMigration")
        case .journalNeedsRepair:
            (.critical, true, .notRetryable, .uncertain, "repairJournal")
        case .orphanSSOTDirectory:
            (.error, true, .notRetryable, .preserved, "inspectOrphan")
        case .unknownSSOTEntry:
            (.error, true, .notRetryable, .preserved, "inspectUnknownEntry")
        case .databaseSkillMissingDirectory:
            (.error, true, .notRetryable, .uncertain, "restoreSkillDirectory")
        case .contentFingerprintDrift:
            (.error, true, .notRetryable, .preserved, "resolveContentDrift")
        case .rootIdentityChanged:
            (.critical, true, .notRetryable, .uncertain, "restartAfterRootRepair")
        case .permissionDenied:
            (.error, true, .retryable, .uncertain, "fixPermissions")
        case .databaseBusy:
            (.error, true, .retryable, .preserved, "retryLater")
        case .cleanupDebt:
            (.warning, false, .retryable, .preserved, "retryCleanup")
        case .legacyArchiveChanged:
            (.warning, false, .notRetryable, .preserved, "inspectLegacyArchive")
        case .unrecoverable:
            (.critical, true, .notRetryable, .uncertain, "manualRecovery")
        }
        return Self(
            code: code,
            severity: policy.0,
            subjectKind: subjectKind,
            subjectID: subjectID.precomposedStringWithCanonicalMapping,
            retryability: policy.2,
            dataPreservation: policy.3,
            recommendedActionCode: policy.4,
            blocking: policy.1
        )
    }

    static func normalized(_ diagnostics: [Self]) -> [Self] {
        var unique: [String: Self] = [:]
        for diagnostic in diagnostics {
            unique[
                "\(diagnostic.code.rawValue)\0\(diagnostic.subjectKind.rawValue)\0\(diagnostic.subjectID)"
            ] = diagnostic
        }
        return unique.values.sorted {
            if $0.severity.rank != $1.severity.rank {
                return $0.severity.rank > $1.severity.rank
            }
            for pair in [
                ($0.code.rawValue, $1.code.rawValue),
                ($0.subjectKind.rawValue, $1.subjectKind.rawValue),
                ($0.subjectID, $1.subjectID),
            ] where pair.0 != pair.1 {
                return pair.0.utf8.lexicographicallyPrecedes(pair.1.utf8)
            }
            return false
        }
    }
}

nonisolated enum LibraryStartupOutcome: String, Sendable {
    case opened
    case firstRunInitialized
}

nonisolated struct LibraryStartupResult: Sendable {
    let phase: LibraryRuntimePhase
    let readiness: LibraryRuntimeReadiness
    let diagnostics: [LibraryRuntimeDiagnostic]
    let outcome: LibraryStartupOutcome?
    let session: JournaledSSOTWriter?
}

@MainActor
@Observable final class LibraryRuntimeState {
    private(set) var phase: LibraryRuntimePhase = .classifying
    private(set) var readiness: LibraryRuntimeReadiness = .blocked
    private(set) var diagnostics: [LibraryRuntimeDiagnostic] = []
    private(set) var outcome: LibraryStartupOutcome?

    func apply(_ result: LibraryStartupResult) {
        phase = result.phase
        readiness = result.readiness
        diagnostics = result.diagnostics
        outcome = result.outcome
    }
}

nonisolated enum LibraryPersistenceError: Error, LocalizedError {
    case runtimeNotReady

    var errorDescription: String? {
        "The managed library is not ready."
    }
}
