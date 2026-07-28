import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill lifecycle view model")
struct SkillLifecycleViewModelTests {
    @Test("runtime blocks until dependencies are available")
    @MainActor
    func runtimeBlocked() async {
        let model = SkillLifecycleViewModel()
        await model.refresh(skillID: SkillID())
        #expect(model.deletionState == .blocked("Preparing the managed library…"))
        #expect(model.backupState == .blocked("Preparing the managed library…"))
    }

    @Test("refresh publishes verified deletion preview and backup catalog")
    @MainActor
    func refreshesPreviewAndCatalog() async throws {
        let skillID = SkillID()
        let preview = try deletionPreview(skillID: skillID, displayName: "Managed")
        let backup = try backupItem(originalSkillID: skillID, summary: preview.content)
        let model = SkillLifecycleViewModel()
        model.activate(dependencies: lifecycleDependencies(
            deletionPreview: { _ in preview },
            backupCatalog: { [backup] }
        ))

        await model.refresh(skillID: skillID)

        #expect(model.deletionState == .ready(preview))
        #expect(model.backupState == .loaded)
        #expect(model.backups == [backup])
        #expect(model.availableBackupCount == 1)
    }

    @Test("duplicate deletion confirmation executes once")
    @MainActor
    func duplicateDeletionConfirmation() async throws {
        let skillID = SkillID()
        let preview = try deletionPreview(skillID: skillID)
        let probe = LifecycleCallProbe()
        let model = SkillLifecycleViewModel()
        model.activate(dependencies: lifecycleDependencies(
            deletionPreview: { _ in preview },
            delete: { preview, operationID, backupID in
                await probe.recordDelete()
                try await Task.sleep(for: .milliseconds(20))
                return SkillDeletionResult(
                    operationID: operationID,
                    skillID: preview.skillID,
                    backupID: backupID,
                    status: .completed
                )
            }
        ))
        await model.refresh(skillID: skillID)
        model.prepareDeletion()

        async let first: Void = model.confirmDeletion()
        async let second: Void = model.confirmDeletion()
        _ = await (first, second)

        #expect(await probe.deleteCount == 1)
        #expect(model.deletionResult?.status == .completed)
    }

    @Test("expired preview fails closed")
    @MainActor
    func previewExpired() async throws {
        let skillID = SkillID()
        let preview = try deletionPreview(skillID: skillID)
        let model = SkillLifecycleViewModel()
        model.activate(dependencies: lifecycleDependencies(
            deletionPreview: { _ in preview },
            delete: { _, _, _ in throw SkillDeletionError.previewExpired }
        ))
        await model.refresh(skillID: skillID)
        model.prepareDeletion()

        await model.confirmDeletion()

        #expect(model.deletionResult == nil)
        #expect(model.problem == .previewExpired)
    }

    @Test("deletion retry keeps its confirmation context until completion")
    @MainActor
    func retryCannotDismissPendingDeletion() async throws {
        let skillID = SkillID()
        let preview = try deletionPreview(skillID: skillID)
        let readback = SkillDeletionResult(
            operationID: SSOTOperationID(),
            skillID: skillID,
            backupID: SkillBackupID(),
            status: .cleanupPending
        )
        let model = SkillLifecycleViewModel()
        model.activate(dependencies: lifecycleDependencies(
            deletionPreview: { _ in preview },
            retryDeletion: { operationID in
                try await Task.sleep(for: .milliseconds(30))
                return SkillDeletionResult(
                    operationID: operationID,
                    skillID: skillID,
                    backupID: readback.backupID,
                    status: .completed
                )
            }
        ))
        await model.refresh(skillID: skillID)
        model.prepareDeletion()

        let retry = Task { await model.retryDeletion(readback) }
        try await Task.sleep(for: .milliseconds(5))
        model.cancelDeletionPreview()

        #expect(model.isRetryingDeletion)
        #expect(model.pendingDeletion != nil)
        await retry.value
        #expect(model.deletionResult?.status == .completed)
    }

    @Test("restore defaults to SSOT only and reports undistributed result")
    @MainActor
    func restoreDefaultsAndConflictResult() async throws {
        let preview = try restorePreview()
        let item = try backupItem(
            backupID: preview.backupID,
            originalSkillID: preview.originalSkillID,
            summary: preview.summary.content
        )
        let probe = LifecycleCallProbe()
        let model = SkillLifecycleViewModel()
        model.activate(dependencies: lifecycleDependencies(
            backupCatalog: { [item] },
            restorePreview: { _ in preview },
            restore: { preview, restoreDistribution in
                await probe.recordRestore(restoreDistribution)
                return SkillRestoreResult(
                    backupID: preview.backupID,
                    restoredSkillID: preview.targetSkillID,
                    status: .restoredUndistributed,
                    warnings: ["distribution_conflict"]
                )
            }
        ))
        await model.refresh(skillID: nil)
        await model.prepareRestore(item)
        #expect(!model.restoreDistribution)

        await model.confirmRestore()

        #expect(await probe.restoreModes == [false])
        #expect(model.restoreResult?.status == .restoredUndistributed)
        #expect(model.problem == .restoredUndistributed)
    }

    @Test("restore preview preparation rejects duplicate and stale results")
    @MainActor
    func restorePreviewPreparationIsSingleFlight() async throws {
        let first = try restorePreview()
        let second = try restorePreview()
        let firstItem = try backupItem(
            backupID: first.backupID,
            originalSkillID: first.originalSkillID,
            summary: first.summary.content
        )
        let secondItem = try backupItem(
            backupID: second.backupID,
            originalSkillID: second.originalSkillID,
            summary: second.summary.content
        )
        let probe = LifecycleCallProbe()
        let model = SkillLifecycleViewModel()
        model.activate(dependencies: lifecycleDependencies(
            restorePreview: { backupID in
                await probe.holdRestorePreview(backupID)
                return backupID == first.backupID ? first : second
            }
        ))

        let preparation = Task { await model.prepareRestore(firstItem) }
        await probe.waitUntilRestorePreviewStarts()
        await model.prepareRestore(secondItem)
        model.blockRuntime(message: "Unavailable")
        await probe.releaseRestorePreview()
        await preparation.value

        #expect(await probe.restorePreviewIDs == [first.backupID])
        #expect(model.pendingRestore == nil)
        #expect(model.preparingRestoreBackupID == nil)
    }

    @Test("stale selection refresh cannot overwrite the current Skill")
    @MainActor
    func staleSelectionRefresh() async throws {
        let firstID = SkillID()
        let secondID = SkillID()
        let first = try deletionPreview(skillID: firstID, displayName: "First")
        let second = try deletionPreview(skillID: secondID, displayName: "Second")
        let model = SkillLifecycleViewModel()
        model.activate(dependencies: lifecycleDependencies(
            deletionPreview: { skillID in
                if skillID == firstID {
                    try await Task.sleep(for: .milliseconds(30))
                    return first
                }
                return second
            }
        ))

        let stale = Task { await model.refresh(skillID: firstID) }
        try await Task.sleep(for: .milliseconds(5))
        await model.refresh(skillID: secondID)
        await stale.value

        #expect(model.deletionState == .ready(second))
    }
}

private actor LifecycleCallProbe {
    private(set) var deleteCount = 0
    private(set) var restoreModes: [Bool] = []
    private(set) var restorePreviewIDs: [SkillBackupID] = []
    private var restorePreviewStartedContinuation: CheckedContinuation<Void, Never>?
    private var restorePreviewReleaseContinuation: CheckedContinuation<Void, Never>?
    private var restorePreviewReleased = false

    func recordDelete() {
        deleteCount += 1
    }

    func recordRestore(_ restoreDistribution: Bool) {
        restoreModes.append(restoreDistribution)
    }

    func holdRestorePreview(_ backupID: SkillBackupID) async {
        restorePreviewIDs.append(backupID)
        restorePreviewStartedContinuation?.resume()
        restorePreviewStartedContinuation = nil
        guard !restorePreviewReleased else { return }
        guard restorePreviewReleaseContinuation == nil else { return }
        await withCheckedContinuation { restorePreviewReleaseContinuation = $0 }
    }

    func waitUntilRestorePreviewStarts() async {
        guard restorePreviewIDs.isEmpty else { return }
        await withCheckedContinuation { restorePreviewStartedContinuation = $0 }
    }

    func releaseRestorePreview() {
        restorePreviewReleased = true
        restorePreviewReleaseContinuation?.resume()
        restorePreviewReleaseContinuation = nil
    }
}

func lifecycleDependencies(
    deletionPreview: @escaping @Sendable (SkillID) async throws -> SkillDeletionPreview = { _ in
        throw SkillDeletionError.skillNotFound
    },
    delete: @escaping @Sendable (
        SkillDeletionPreview,
        SSOTOperationID,
        SkillBackupID
    ) async throws -> SkillDeletionResult = { _, _, _ in
        throw SkillDeletionError.unavailable
    },
    retryDeletion: @escaping @Sendable (
        SSOTOperationID
    ) async throws -> SkillDeletionResult = { _ in
        throw SkillDeletionError.unavailable
    },
    deletionReadback: @escaping @Sendable (
        SSOTOperationID
    ) async throws -> SkillDeletionResult = { _ in
        throw SkillDeletionError.skillNotFound
    },
    recoverableDeletions: @escaping @Sendable () async throws -> [SkillDeletionResult] = { [] },
    backupCatalog: @escaping @Sendable () async throws -> [SkillBackupCatalogItem] = { [] },
    setBackupPinned: @escaping @Sendable (
        SkillBackupID,
        Bool
    ) async throws -> SkillBackupRecord = { _, _ in
        throw SkillDeletionError.unavailable
    },
    restorePreview: @escaping @Sendable (
        SkillBackupID
    ) async throws -> SkillRestorePreview = { _ in
        throw SkillDeletionError.backupCorrupt
    },
    restore: @escaping @Sendable (
        SkillRestorePreview,
        Bool
    ) async throws -> SkillRestoreResult = { _, _ in
        throw SkillDeletionError.unavailable
    }
) -> SkillLifecycleDependencies {
    SkillLifecycleDependencies(
        deletionPreview: deletionPreview,
        delete: delete,
        retryDeletion: retryDeletion,
        deletionReadback: deletionReadback,
        recoverableDeletions: recoverableDeletions,
        backupCatalog: backupCatalog,
        setBackupPinned: setBackupPinned,
        restorePreview: restorePreview,
        restore: restore
    )
}

func deletionPreview(
    skillID: SkillID,
    displayName: String = "Managed"
) throws -> SkillDeletionPreview {
    let fingerprint = try lifecycleFingerprint()
    let statistics = SkillContentSnapshot.Statistics(fileCount: 2, totalByteCount: 128)
    let content = SkillContentSummary(
        displayName: displayName,
        contentFingerprint: fingerprint,
        statistics: statistics
    )
    return SkillDeletionPreview(
        skillID: skillID,
        displayName: displayName,
        content: content,
        targets: [
            SkillDistributionTargetSummary(
                scopeKey: DistributionBindingScope.global.targetScopeKey,
                canonicalLocator: "~/.agents/skills/managed"
            ),
        ],
        status: .ready,
        operation: nil,
        token: SkillDeletionPreviewToken(
            skillID: skillID,
            databaseRevision: 1,
            domainPayload: Data([1]),
            expectationPayload: Data([2]),
            ssotIdentity: lifecycleIdentity(),
            contentFingerprint: fingerprint,
            statistics: statistics
        )
    )
}

private func restorePreview() throws -> SkillRestorePreview {
    let backupID = SkillBackupID()
    let originalSkillID = SkillID()
    let summary = SkillBackupSummary(
        content: SkillContentSummary(
            displayName: "Restorable",
            contentFingerprint: try lifecycleFingerprint(),
            statistics: SkillContentSnapshot.Statistics(fileCount: 2, totalByteCount: 128)
        ),
        sourceLocator: "https://github.com/example/skills#demo",
        targets: [
            SkillDistributionTargetSummary(
                scopeKey: DistributionBindingScope.global.targetScopeKey,
                canonicalLocator: "~/.agents/skills/restorable"
            ),
        ]
    )
    return SkillRestorePreview(
        backupID: backupID,
        originalSkillID: originalSkillID,
        targetSkillID: originalSkillID,
        status: .ready,
        summary: summary,
        token: SkillRestorePreviewToken(
            backupUpdatedAtMilliseconds: 2,
            directoryIdentity: lifecycleIdentity(),
            manifestDigest: Data(repeating: 3, count: 32),
            contentFingerprint: summary.content.contentFingerprint,
            targetSkillID: originalSkillID,
            targetRevision: nil,
            targetPayload: nil
        )
    )
}

private func backupItem(
    backupID: SkillBackupID = SkillBackupID(),
    originalSkillID: SkillID,
    summary content: SkillContentSummary?
) throws -> SkillBackupCatalogItem {
    SkillBackupCatalogItem(
        backupID: backupID,
        originalSkillID: originalSkillID,
        availability: .available,
        isPinned: false,
        restoredSkillID: nil,
        createdAtMilliseconds: 1,
        summary: content.map {
            SkillBackupSummary(content: $0, sourceLocator: nil, targets: [])
        },
        problem: nil
    )
}

private func lifecycleFingerprint() throws -> SkillContentFingerprint {
    try SkillContentFingerprint(currentDigest: Data(repeating: 7, count: 32))
}

private func lifecycleIdentity() -> ManagedItemIdentity {
    ManagedItemIdentity(persistedComponents: ManagedItemIdentityPersistedComponents(
        device: 1,
        inode: 2,
        fileType: 4,
        generation: 0
    ))
}
