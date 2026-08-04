import Darwin
import Foundation

nonisolated enum ManagedLocalImportScope: Equatable, Sendable {
    case global
    case agents(Set<SkillPlatform>)

    func desiredScope(slug: DefaultDistributionSlug) throws -> DistributionDesiredScope {
        switch self {
        case .global:
            return .global(slug)
        case .agents(let agents):
            guard !agents.isEmpty else { throw ManagedLocalImportProblem.emptyAgentSelection }
            return .agents(agents, slug)
        }
    }
}

nonisolated struct ManagedLocalImportToken: Hashable, Sendable {
    let uuid: UUID

    init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

nonisolated struct ManagedLocalImportPreview: Identifiable, Sendable {
    enum Disposition: Equatable, Sendable {
        case createNew
        case alreadyManaged
        case updateRequired
    }

    let token: ManagedLocalImportToken
    let skillID: SkillID
    let displayName: SkillDisplayName
    let distributionSlug: DefaultDistributionSlug
    let desiredScope: DistributionDesiredScope
    let plan: DistributionPlan
    let disposition: Disposition
    let allowsBlockedCreate: Bool
    let source: ManagedInstallSourcePreview?

    var id: ManagedLocalImportToken { token }
}

nonisolated struct ManagedInstallSourcePreview: Equatable, Sendable {
    let repositoryURL: NormalizedRepositoryURL
    let subpath: RepositorySubpath
    let revision: SourceRevision
    let downloadURL: PublicDownloadURL
    let alias: ProviderAliasIdentity
}

nonisolated enum ManagedLocalImportResultStatus: Equatable, Sendable {
    case distributed
    case noDistributionChanges
    case managedUndistributed
    case managedDistributionIndeterminate
    case managementIndeterminate
    case alreadyManaged
    case updateRequired
    case updated
    case updatedDistributionNeedsAttention
    case updateIndeterminate
}

nonisolated struct ManagedLocalImportResult: Equatable, Sendable {
    let skillID: SkillID
    let displayName: String
    let status: ManagedLocalImportResultStatus
}

nonisolated enum ManagedLocalImportProblem: LocalizedError, Equatable, Sendable {
    case emptyAgentSelection
    case invalidCandidate
    case operationInProgress
    case permissionDenied
    case previewBlocked
    case previewExpired
    case createRolledBack
    case updateRolledBack
    case needsRepair
    case sourceChanged
    case tokenExpired
    case providerConflict
    case providerAliasConflict
    case sourceUpdateUnsupportedLocalOrigins
    case aliasLimitReached
    case failed(String)
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyAgentSelection:
            "Select at least one Agent."
        case .invalidCandidate:
            "The selected Skill is no longer valid."
        case .operationInProgress:
            "This import is already in progress."
        case .permissionDenied:
            "Skills Manager does not have permission to import this Skill."
        case .previewBlocked:
            "Resolve the distribution conflicts before importing."
        case .previewExpired:
            "The import preview changed. Review it again before importing."
        case .createRolledBack:
            "The Skill was not imported because the managed write was rolled back."
        case .updateRolledBack:
            "The update was rolled back. The previous managed content is still available."
        case .needsRepair:
            "The managed library requires repair before another import can start."
        case .sourceChanged:
            "The selected Skill changed after validation. Choose it again."
        case .tokenExpired:
            "The import preview expired. Prepare a new preview."
        case .providerConflict:
            "The ClawHub source record conflicts with another managed Skill."
        case .providerAliasConflict:
            "This skills.sh result is already linked to a different managed source."
        case .sourceUpdateUnsupportedLocalOrigins:
            "This managed Skill also has local origins and cannot be safely updated from skills.sh."
        case .aliasLimitReached:
            "This managed Skill has reached the Provider alias limit."
        case .failed(let detail):
            "Import failed: \(detail)"
        case .updateFailed(let detail):
            "Update failed: \(detail)"
        }
    }
}

nonisolated func managedInstallKnownProblem(
    for error: Error
) -> ManagedLocalImportProblem? {
    if error is CancellationError {
        return .failed("Import was cancelled.")
    }
    if let error = error as? JournaledSSOTWriterError {
        switch error {
        case .operationNeedsRepair:
            return .needsRepair
        case .operationRolledBack:
            return .createRolledBack
        case .invalidInput, .recoveryDidNotConverge:
            return nil
        }
    }
    if let error = error as? ManagedSkillUpdateBackupError {
        return switch error {
        case .skillNotFound, .baselineDrift:
            .previewExpired
        case .backupNeedsRepair:
            .needsRepair
        }
    }
    if let error = error as? SourceInstallAdmissionError {
        return switch error {
        case .previewExpired:
            .previewExpired
        case .providerAliasConflict:
            .providerAliasConflict
        case .invalidInput:
            nil
        }
    }
    if let error = error as? CopyForkError {
        return switch error {
        case .operationInProgress:
            .operationInProgress
        case .needsRepair:
            .needsRepair
        case .permissionDenied:
            .permissionDenied
        case .notCopy, .notContentOnlyDrift, .previewExpired,
             .unsafeContent, .targetUnavailable, .bindingConflict:
            nil
        }
    }
    if let error = error as? SSOTWriterOwnershipError {
        switch error {
        case .busy:
            return .operationInProgress
        case .posix(_, let code) where isPermissionPOSIXCode(code):
            return .permissionDenied
        default:
            return nil
        }
    }
    if let error = error as? SSOTOperationFileSystemError,
       case .posix(_, let code) = error,
       isPermissionPOSIXCode(code) {
        return .permissionDenied
    }
    if let error = error as? SSOTDurabilityError,
       case .posix(_, let code) = error,
       isPermissionPOSIXCode(code) {
        return .permissionDenied
    }
    if let error = error as? SkillBackupFileSystemError,
       case .posix(_, let code) = error,
       isPermissionPOSIXCode(code) {
        return .permissionDenied
    }
    if let error = error as? SkillContentSnapshotError {
        if case .fileSystemFailure(_, let code) = error,
           isPermissionPOSIXCode(code) {
            return .permissionDenied
        }
        return .sourceChanged
    }
    if let error = error as? ManagedPathError {
        if case .posix(_, let code) = error,
           isPermissionPOSIXCode(code) {
            return .permissionDenied
        }
        return nil
    }
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain,
       nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
        return .permissionDenied
    }
    return nil
}

private nonisolated func isPermissionPOSIXCode(_ code: Int32) -> Bool {
    code == EACCES || code == EPERM
}

nonisolated struct ManagedInstallProviderInput: Sendable {
    let identity: ProviderAliasIdentity
    let identifierKey: String
    let version: SourceVersion?

    init(slug: DefaultDistributionSlug, version: String?) throws {
        identity = try ProviderAliasIdentity(provider: "clawdhub", identifier: slug.value)
        identifierKey = slug.collisionKey
        self.version = try version.map(SourceVersion.init)
    }

    func record(skillID: SkillID) throws -> ProviderProvenanceRecord {
        try ProviderProvenanceRecord(
            skillID: skillID,
            identity: identity,
            identifierKey: identifierKey,
            version: version
        )
    }
}

nonisolated struct ManagedSourceInstallInput: Sendable {
    let displayName: String
    let distributionSlug: DefaultDistributionSlug
    let repositoryURL: NormalizedRepositoryURL
    let subpath: RepositorySubpath
    let revision: SourceRevision
    let downloadURL: PublicDownloadURL
    let alias: ProviderAliasIdentity
    let refreshHead: @Sendable () async throws -> SourceRevision
    let finalAdmission: @Sendable () async throws -> Void

    init(
        displayName: String,
        distributionSlug: DefaultDistributionSlug,
        repositoryURL: NormalizedRepositoryURL,
        subpath: RepositorySubpath,
        revision: SourceRevision,
        downloadURL: PublicDownloadURL,
        alias: ProviderAliasIdentity,
        refreshHead: @escaping @Sendable () async throws -> SourceRevision,
        finalAdmission: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.displayName = displayName
        self.distributionSlug = distributionSlug
        self.repositoryURL = repositoryURL
        self.subpath = subpath
        self.revision = revision
        self.downloadURL = downloadURL
        self.alias = alias
        self.refreshHead = refreshHead
        self.finalAdmission = finalAdmission
    }

    var preview: ManagedInstallSourcePreview {
        ManagedInstallSourcePreview(
            repositoryURL: repositoryURL,
            subpath: subpath,
            revision: revision,
            downloadURL: downloadURL,
            alias: alias
        )
    }
}

nonisolated struct ManagedPreparedSource: Sendable {
    let input: ManagedSourceInstallInput
    let sourceID: SourceID
    let admission: SourceInstallAdmissionExpectation
}

nonisolated struct ManagedInstallDependencies: Sendable {
    let plan: @Sendable (
        SkillID,
        DistributionDesiredScope,
        Set<String>
    ) async throws -> DistributionPlan
    let create: @Sendable (
        SSOTSkillWritePayload,
        SkillContentSnapshot,
        SSOTOperationID
    ) async throws -> SSOTJournalRecord
    let operationReadback: @Sendable (SSOTOperationID) async throws -> SSOTJournalRecord
    let domainReadback: @Sendable (SkillID) async throws -> SSOTSkillWritePayload?
    let provenanceReadback: @Sendable (
        ProviderAliasIdentity
    ) async throws -> ProviderProvenanceRecord?
    let sourceReadback: @Sendable (
        NormalizedRepositoryURL,
        RepositorySubpath
    ) async throws -> StoredSkillDomainSnapshot?
    let aliasOwnerReadback: @Sendable (
        ProviderAliasIdentity
    ) async throws -> ProviderAliasSourceOwner?
    let updateBaseline: @Sendable (SkillID) async throws -> ManagedSkillUpdateBaseline
    let replaceWithBackup: @Sendable (
        ManagedSkillUpdateBaseline,
        SSOTSkillWritePayload,
        SkillContentSnapshot,
        SSOTOperationID,
        SkillBackupID
    ) async throws -> ManagedSkillUpdateWriteResult
    let createSourceBacked: @Sendable (
        SSOTSkillWritePayload,
        SkillContentSnapshot,
        SSOTOperationID,
        SourceInstallAdmissionExpectation
    ) async throws -> SSOTJournalRecord
    let replaceSourceBackedWithBackup: @Sendable (
        ManagedSkillUpdateBaseline,
        SSOTSkillWritePayload,
        SkillContentSnapshot,
        SSOTOperationID,
        SkillBackupID,
        SourceInstallAdmissionExpectation
    ) async throws -> ManagedSkillUpdateWriteResult
    let apply: @Sendable (SkillID, DistributionPlan) async throws -> DistributionOperationRecord
    let reconcile: @Sendable (SkillID) async throws -> DistributionReconcileResult
    let nowMilliseconds: @Sendable () -> Int64

    static func live(writer: JournaledSSOTWriter) -> Self {
        let distribution = SkillDistributionDependencies.live(writer: writer)
        return Self(
            plan: { skillID, scope, requiredAdapterCodes in
                try await distribution.plan(
                    skillID,
                    DistributionDesiredConfiguration(
                        scope: scope,
                        syncMode: .symlink
                    ),
                    requiredAdapterCodes
                )
            },
            create: { payload, snapshot, operationID in
                try await writer.create(
                    payload: payload,
                    sourceSnapshot: snapshot,
                    operationID: operationID
                )
            },
            operationReadback: { try await writer.ssotOperationReadback($0) },
            domainReadback: { try await writer.storedDomainReadback($0)?.payload },
            provenanceReadback: { try await writer.providerProvenance($0) },
            sourceReadback: {
                try await writer.sourceDomainReadback(repositoryURL: $0, subpath: $1)
            },
            aliasOwnerReadback: { try await writer.providerAliasOwnerReadback($0) },
            updateBaseline: { try await writer.managedSkillUpdateBaseline($0) },
            replaceWithBackup: { baseline, payload, snapshot, operationID, backupID in
                try await writer.replaceManagedSkillWithBackup(
                    expected: baseline,
                    replacementPayload: payload,
                    sourceSnapshot: snapshot,
                    operationID: operationID,
                    backupID: backupID
                )
            },
            createSourceBacked: { payload, snapshot, operationID, admission in
                try await writer.createSourceBacked(
                    payload: payload,
                    sourceSnapshot: snapshot,
                    operationID: operationID,
                    admission: admission
                )
            },
            replaceSourceBackedWithBackup: {
                baseline, payload, snapshot, operationID, backupID, admission in
                try await writer.replaceSourceBackedWithBackup(
                    expected: baseline,
                    replacementPayload: payload,
                    sourceSnapshot: snapshot,
                    operationID: operationID,
                    backupID: backupID,
                    admission: admission
                )
            },
            apply: distribution.apply,
            reconcile: distribution.reconcile,
            nowMilliseconds: { max(0, Int64(Date().timeIntervalSince1970 * 1_000)) }
        )
    }
}
