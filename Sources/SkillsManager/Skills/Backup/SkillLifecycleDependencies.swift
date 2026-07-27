nonisolated struct SkillLifecycleDependencies: Sendable {
    let deletionPreview: @Sendable (SkillID) async throws -> SkillDeletionPreview
    let delete: @Sendable (
        SkillDeletionPreview,
        SSOTOperationID,
        SkillBackupID
    ) async throws -> SkillDeletionResult
    let retryDeletion: @Sendable (SSOTOperationID) async throws -> SkillDeletionResult
    let deletionReadback: @Sendable (SSOTOperationID) async throws -> SkillDeletionResult
    let recoverableDeletions: @Sendable () async throws -> [SkillDeletionResult]
    let backupCatalog: @Sendable () async throws -> [SkillBackupCatalogItem]
    let setBackupPinned: @Sendable (
        SkillBackupID,
        Bool
    ) async throws -> SkillBackupRecord
    let restorePreview: @Sendable (SkillBackupID) async throws -> SkillRestorePreview
    let restore: @Sendable (
        SkillRestorePreview,
        Bool
    ) async throws -> SkillRestoreResult

    static func live(writer: JournaledSSOTWriter) -> Self {
        let session = SkillLifecycleSession(writer: writer)
        return Self(
            deletionPreview: { try await session.deletionPreview(skillID: $0) },
            delete: {
                try await session.delete(preview: $0, operationID: $1, backupID: $2)
            },
            retryDeletion: { try await session.retryDeletion($0) },
            deletionReadback: { try await session.deletionReadback($0) },
            recoverableDeletions: { try await session.recoverableDeletions() },
            backupCatalog: { try await session.backupCatalog() },
            setBackupPinned: { try await session.setBackupPinned($0, isPinned: $1) },
            restorePreview: { try await session.restorePreview($0) },
            restore: { try await session.restore(preview: $0, restoreDistribution: $1) }
        )
    }
}

private actor SkillLifecycleSession {
    private let writer: JournaledSSOTWriter

    init(writer: JournaledSSOTWriter) {
        self.writer = writer
    }

    func deletionPreview(skillID: SkillID) async throws -> SkillDeletionPreview {
        try await writer.deletionPreview(skillID: skillID)
    }

    func delete(
        preview: SkillDeletionPreview,
        operationID: SSOTOperationID,
        backupID: SkillBackupID
    ) async throws -> SkillDeletionResult {
        try await writer.deleteManagedSkill(
            preview: preview,
            operationID: operationID,
            backupID: backupID
        )
    }

    func retryDeletion(_ operationID: SSOTOperationID) async throws -> SkillDeletionResult {
        try await writer.retryDeletion(operationID)
    }

    func deletionReadback(_ operationID: SSOTOperationID) async throws -> SkillDeletionResult {
        try await writer.deletionReadback(operationID)
    }

    func recoverableDeletions() async throws -> [SkillDeletionResult] {
        try await writer.recoverableDeletionReadbacks()
    }

    func backupCatalog() async throws -> [SkillBackupCatalogItem] {
        try await writer.backupCatalog()
    }

    func setBackupPinned(
        _ backupID: SkillBackupID,
        isPinned: Bool
    ) async throws -> SkillBackupRecord {
        try await writer.setBackupPinned(backupID, isPinned: isPinned)
    }

    func restorePreview(_ backupID: SkillBackupID) async throws -> SkillRestorePreview {
        try await writer.restorePreview(backupID)
    }

    func restore(
        preview: SkillRestorePreview,
        restoreDistribution: Bool
    ) async throws -> SkillRestoreResult {
        try await writer.restoreBackup(
            preview: preview,
            restoreDistribution: restoreDistribution
        )
    }
}
