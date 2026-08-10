import Foundation
import Observation

nonisolated struct SkillConsistencyDependencies: Sendable {
    let audit: @Sendable () async throws -> SkillConsistencyAuditPrepared
    let prepareRepair:
        @Sendable (SkillID, SkillConsistencyRepairAction)
            async throws -> SkillConsistencyRepairPreview
    let confirmRepair:
        @Sendable (SkillConsistencyRepairPreview)
            async throws -> SkillConsistencyRepairResult
    let prepareMigration:
        @Sendable (
            SkillConsistencyAuditPrepared,
            SkillDiscoveryObservation,
            ManagedSkillImportAction?
        ) async throws -> HistoricalSkillMigrationPreview
    let confirmMigration:
        @Sendable (HistoricalSkillMigrationToken)
            async throws -> Void

    static func live(writer: JournaledSSOTWriter) -> Self {
        let session = SkillConsistencySession(writer: writer)
        return Self(
            audit: { try await session.audit() },
            prepareRepair: { try await session.prepareRepair($0, action: $1) },
            confirmRepair: { try await session.confirmRepair($0) },
            prepareMigration: {
                try await session.prepareMigration(
                    audit: $0,
                    observation: $1,
                    importAction: $2
                )
            },
            confirmMigration: { try await session.confirmMigration($0) }
        )
    }
}

private actor SkillConsistencySession {
    private let auditService: SkillConsistencyAuditService
    private let repairService: SkillConsistencyRepairService
    private let migrationService: HistoricalSkillMigrationService

    init(writer: JournaledSSOTWriter) {
        auditService = SkillConsistencyAuditService(writer: writer)
        repairService = SkillConsistencyRepairService(writer: writer)
        migrationService = HistoricalSkillMigrationService(writer: writer)
    }

    func audit() async throws -> SkillConsistencyAuditPrepared {
        try await auditService.prepare()
    }

    func prepareRepair(
        _ skillID: SkillID,
        action: SkillConsistencyRepairAction
    ) async throws -> SkillConsistencyRepairPreview {
        try await repairService.prepare(skillID: skillID, action: action)
    }

    func confirmRepair(
        _ preview: SkillConsistencyRepairPreview
    ) async throws -> SkillConsistencyRepairResult {
        try await repairService.confirm(preview)
    }

    func prepareMigration(
        audit: SkillConsistencyAuditPrepared,
        observation: SkillDiscoveryObservation,
        importAction: ManagedSkillImportAction?
    ) async throws -> HistoricalSkillMigrationPreview {
        try await migrationService.prepare(
            audit: audit,
            observation: observation,
            importAction: importAction
        )
    }

    func confirmMigration(
        _ token: HistoricalSkillMigrationToken
    ) async throws {
        let result = try await migrationService.confirm(token)
        guard result.distribution.phase == .completed,
              result.distribution.outcome == .applied else {
            throw HistoricalSkillMigrationError.needsRepair
        }
    }
}

@MainActor
@Observable final class SkillConsistencyViewModel {
    enum LoadState: Sendable, Equatable {
        case blocked(String)
        case auditing
        case ready(SkillConsistencyPresentation.Snapshot)
        case failed(Problem)
    }

    struct Problem: Sendable, Equatable {
        enum Kind: Sendable {
            case stale
            case permission
            case operationInProgress
            case needsRepair
            case partial
            case unavailable
        }

        let kind: Kind
        let message: String

        var showsBackups: Bool {
            kind == .needsRepair || kind == .partial
        }
    }

    struct PendingPreview: Identifiable, Sendable {
        enum Payload: Sendable {
            case repair(SkillConsistencyRepairPreview)
            case migration(HistoricalSkillMigrationPreview)
        }

        let id: UUID
        let title: String
        let summary: String
        let details: [String]
        let affectedFindingIDs: Set<String>
        let generation: UInt64
        let payload: Payload
    }

    private(set) var loadState: LoadState =
        .blocked(String(localized: "Preparing the managed library…", bundle: .module))
    private(set) var pendingPreview: PendingPreview?
    private(set) var problem: Problem?
    private(set) var successMessage: String?
    private(set) var isPreparingPreview = false
    private(set) var isExecuting = false
    private(set) var isVerifying = false
    private(set) var keptFindingIDs: Set<String> = []

    private var dependencies: SkillConsistencyDependencies?
    private var preparedAudit: SkillConsistencyAuditPrepared?
    private var runtimeReady = false
    private var runtimeBlockMessage = String(localized: "Preparing the managed library…", bundle: .module)
    private var generation: UInt64 = 0
    private var auditRequested = false

    var snapshot: SkillConsistencyPresentation.Snapshot? {
        if case .ready(let snapshot) = loadState { snapshot } else { nil }
    }

    var canRefresh: Bool {
        runtimeReady && !isPreparingPreview && !isExecuting && !isVerifying
    }

    var hasAudited: Bool { auditRequested }

    @discardableResult
    func activate(dependencies: SkillConsistencyDependencies) -> Bool {
        let needsRefresh = !runtimeReady
        self.dependencies = dependencies
        runtimeReady = true
        if preparedAudit == nil {
            loadState = .blocked(String(localized: "Run an audit to inspect the managed library.", bundle: .module))
        }
        return needsRefresh
    }

    func blockRuntime(message: String) {
        runtimeReady = false
        runtimeBlockMessage = message
        generation &+= 1
        preparedAudit = nil
        pendingPreview = nil
        keptFindingIDs = []
        isPreparingPreview = false
        loadState = .blocked(message)
    }

    func refreshIfLoaded() async {
        guard hasAudited else { return }
        await refresh()
    }

    func refresh() async {
        auditRequested = true
        guard canRefresh, let dependencies else {
            if !runtimeReady { loadState = .blocked(runtimeBlockMessage) }
            return
        }
        generation &+= 1
        let refreshGeneration = generation
        pendingPreview = nil
        problem = nil
        successMessage = nil
        keptFindingIDs = []
        loadState = .auditing
        do {
            let prepared = try await dependencies.audit()
            let snapshot = try SkillConsistencyPresentation.makeSnapshot(prepared)
            guard generation == refreshGeneration else { return }
            preparedAudit = prepared
            loadState = .ready(snapshot)
        } catch {
            guard generation == refreshGeneration else { return }
            preparedAudit = nil
            loadState = .failed(Self.problem(for: error))
        }
    }

    func isKept(_ findingID: String) -> Bool {
        keptFindingIDs.contains(findingID)
    }

    func prepare(
        findingID: String,
        action: SkillConsistencyPresentation.Action
    ) async {
        guard !isPreparingPreview, !isExecuting, !isVerifying,
              problem == nil,
              let snapshot,
              snapshot.allowsWrites,
              let preparedAudit,
              let dependencies,
              let finding = snapshot.findings.first(where: { $0.id == findingID }),
              finding.actions.contains(action) else {
            return
        }
        if action == .keepForNow {
            keptFindingIDs.insert(findingID)
            pendingPreview = nil
            problem = nil
            successMessage = String(
                localized: "Kept for this session. A future audit will show it again.",
                bundle: .module
            )
            return
        }

        isPreparingPreview = true
        defer { isPreparingPreview = false }
        pendingPreview = nil
        problem = nil
        successMessage = nil
        let previewGeneration = generation
        do {
            let preview = try await makePreview(
                finding: finding,
                action: action,
                preparedAudit: preparedAudit,
                dependencies: dependencies,
                generation: previewGeneration
            )
            guard generation == previewGeneration else { return }
            pendingPreview = preview
        } catch {
            guard generation == previewGeneration else { return }
            problem = Self.problem(for: error)
        }
    }

    func cancelPreview() {
        guard !isExecuting, !isVerifying else { return }
        pendingPreview = nil
    }

    func confirmPreview() async {
        guard !isExecuting, !isVerifying,
              let preview = pendingPreview,
              preview.generation == generation,
              let dependencies else {
            return
        }
        isExecuting = true
        problem = nil
        successMessage = nil
        do {
            switch preview.payload {
            case .repair(let repair):
                let result = try await dependencies.confirmRepair(repair)
                guard result != .skipped else {
                    throw SkillConsistencyRepairError.stalePreview
                }
            case .migration(let migration):
                try await dependencies.confirmMigration(migration.token)
            }
            isExecuting = false
            try await verify(preview, dependencies: dependencies)
        } catch {
            isExecuting = false
            isVerifying = false
            pendingPreview = nil
            problem = Self.problem(for: error)
        }
    }

    private func makePreview(
        finding: SkillConsistencyPresentation.Finding,
        action: SkillConsistencyPresentation.Action,
        preparedAudit: SkillConsistencyAuditPrepared,
        dependencies: SkillConsistencyDependencies,
        generation: UInt64
    ) async throws -> PendingPreview {
        switch action {
        case .rebuildMissingSymlinks(let scopeKeys):
            guard let skillID = finding.skillID else {
                throw SkillConsistencyRepairError.invalidSelection
            }
            let repair = try await dependencies.prepareRepair(
                skillID,
                .rebuildMissingSymlink(scopeKeys: scopeKeys)
            )
            return PendingPreview(
                id: repair.confirmationID,
                title: String(localized: "Rebuild missing links", bundle: .module),
                summary: String(localized: "Recreate every missing managed Symlink for this Skill.", bundle: .module),
                details: scopeKeys.sorted(),
                affectedFindingIDs: finding.affectedFindingIDs,
                generation: generation,
                payload: .repair(repair)
            )
        case .disableMissingBinding(let scopeKeys):
            guard let skillID = finding.skillID else {
                throw SkillConsistencyRepairError.invalidSelection
            }
            let repair = try await dependencies.prepareRepair(
                skillID,
                .disableMissingBinding(scopeKeys: scopeKeys)
            )
            return PendingPreview(
                id: repair.confirmationID,
                title: String(localized: "Disable missing target", bundle: .module),
                summary: String(localized: "Remove the selected missing target from managed distribution.", bundle: .module),
                details: scopeKeys.sorted(),
                affectedFindingIDs: [finding.id],
                generation: generation,
                payload: .repair(repair)
            )
        case .migrate(let importAction, let independent):
            guard let observation = finding.observation else {
                throw HistoricalSkillMigrationError.unsupportedCandidate
            }
            let migration = try await dependencies.prepareMigration(
                preparedAudit,
                observation,
                importAction
            )
            var details = [
                String(localized: LocalizedStringResource(
            "Source: \(migration.sourceLocator)",
            bundle: .module
        )),
                String(localized: LocalizedStringResource(
            "SSOT: \(migration.ssotAbsoluteTarget)",
            bundle: .module
        )),
                String(localized: LocalizedStringResource(
            "Backup: \(migration.backupID.uuid.uuidString.lowercased())",
            bundle: .module
        )),
                String(localized: LocalizedStringResource(
            "Operation: \(migration.operationID.uuid.uuidString.lowercased())",
            bundle: .module
        )),
            ]
            if independent {
                details.insert(String(localized: "Identity: new independent Skill UUID", bundle: .module), at: 0)
            }
            let localizedTitle: String
            switch action {
            case .migrate(.importNew, true):
                localizedTitle = String(localized: "Import as independent Skill, back up and migrate", bundle: .module)
            case .migrate(.importNew, false):
                localizedTitle = String(localized: "Import, back up and migrate", bundle: .module)
            case .migrate(.claimExisting, _):
                localizedTitle = String(localized: "Claim, back up and migrate", bundle: .module)
            case .migrate(nil, _), .keepForNow, .rebuildMissingSymlinks(_), .disableMissingBinding(_):
                localizedTitle = String(localized: "Back up and migrate", bundle: .module)
            }
            return PendingPreview(
                id: migration.token.uuid,
                title: localizedTitle,
                summary: String(localized: "Back up the original directory, then replace it with a managed Symlink.", bundle: .module),
                details: details,
                affectedFindingIDs: [finding.id],
                generation: generation,
                payload: .migration(migration)
            )
        case .keepForNow:
            throw SkillConsistencyRepairError.invalidSelection
        }
    }

    private func verify(
        _ preview: PendingPreview,
        dependencies: SkillConsistencyDependencies
    ) async throws {
        isVerifying = true
        defer { isVerifying = false }
        guard runtimeReady, preview.generation == generation else {
            throw SkillConsistencyAuditError.sourceChanged
        }
        let prepared = try await dependencies.audit()
        let verified = try SkillConsistencyPresentation.makeSnapshot(prepared)
        let unresolved = Set(verified.findings.map(\.id))
            .intersection(preview.affectedFindingIDs)
        guard verified.status != .incomplete,
              verified.status != .blocked,
              verified.status != .operationInProgress,
              verified.status != .needsRepair,
              unresolved.isEmpty else {
            throw VerificationError.incomplete
        }
        preparedAudit = prepared
        loadState = .ready(verified)
        generation &+= 1
        pendingPreview = nil
        keptFindingIDs = []
        successMessage = String(localized: "Completed and verified by a fresh consistency audit.", bundle: .module)
    }

    private enum VerificationError: Error {
        case incomplete
    }

    private static func problem(for error: Error) -> Problem {
        if error is VerificationError {
            return Problem(
                kind: .partial,
                message: String(localized: "The operation finished, but a fresh audit could not verify consistency.", bundle: .module)
            )
        }
        if let error = error as? SkillConsistencyAuditError {
            return switch error {
            case .sourceChanged:
                Problem(kind: .stale, message: String(localized: "The library changed. Refresh the audit.", bundle: .module))
            case .permissionDenied:
                Problem(kind: .permission, message: String(localized: "Permission denied while auditing the library.", bundle: .module))
            case .inconsistentCatalog:
                Problem(kind: .needsRepair, message: String(localized: "Managed catalog repair is required.", bundle: .module))
            case .rootUnavailable, .databaseUnavailable, .writerUnavailable:
                Problem(kind: .unavailable, message: String(localized: "The managed library is unavailable.", bundle: .module))
            }
        }
        if let error = error as? SkillConsistencyRepairError {
            return switch error {
            case .stalePreview:
                Problem(kind: .stale, message: String(localized: "The preview is stale. Refresh the audit.", bundle: .module))
            case .permissionDenied:
                Problem(kind: .permission, message: String(localized: "Permission denied while applying the repair.", bundle: .module))
            case .operationInProgress:
                Problem(kind: .operationInProgress, message: String(localized: "Another operation is in progress.", bundle: .module))
            case .needsRepair:
                Problem(kind: .needsRepair, message: String(localized: "The operation requires manual recovery.", bundle: .module))
            default:
                Problem(kind: .unavailable, message: String(localized: "This repair is not currently available.", bundle: .module))
            }
        }
        if let error = error as? HistoricalSkillMigrationError {
            return switch error {
            case .stalePreview, .sourceChanged:
                Problem(kind: .stale, message: String(localized: "The source changed. Refresh the audit.", bundle: .module))
            case .permissionDenied:
                Problem(kind: .permission, message: String(localized: "Permission denied while migrating the Skill.", bundle: .module))
            case .operationInProgress:
                Problem(kind: .operationInProgress, message: String(localized: "Another operation is in progress.", bundle: .module))
            case .needsRepair, .backupUnavailable:
                Problem(kind: .needsRepair, message: String(localized: "Migration recovery is required.", bundle: .module))
            default:
                Problem(kind: .unavailable, message: String(localized: "This migration is not currently available.", bundle: .module))
            }
        }
        return Problem(kind: .unavailable, message: String(localized: "The operation could not be completed.", bundle: .module))
    }
}
