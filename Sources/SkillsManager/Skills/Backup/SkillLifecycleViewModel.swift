import Foundation
import Observation

@MainActor
@Observable final class SkillLifecycleViewModel {
    enum DeletionLoadState: Equatable {
        case blocked(String)
        case empty
        case loading
        case ready(SkillDeletionPreview)
        case failed(Problem)
    }

    enum BackupLoadState: Equatable {
        case blocked(String)
        case loading
        case loaded
        case failed(Problem)
    }

    struct PendingDeletion: Identifiable, Equatable, Sendable {
        let id = UUID()
        let preview: SkillDeletionPreview
        let operationID: SSOTOperationID
        let backupID: SkillBackupID
    }

    struct PendingRestore: Identifiable, Equatable, Sendable {
        let id = UUID()
        let preview: SkillRestorePreview
    }

    private(set) var deletionState: DeletionLoadState =
        .blocked("Preparing the managed library…")
    private(set) var backupState: BackupLoadState =
        .blocked("Preparing the managed library…")
    private(set) var backups: [SkillBackupCatalogItem] = []
    private(set) var recoverableDeletions: [SkillDeletionResult] = []
    private(set) var pendingDeletion: PendingDeletion?
    private(set) var pendingRestore: PendingRestore?
    private(set) var deletionResult: SkillDeletionResult?
    private(set) var restoreResult: SkillRestoreResult?
    private(set) var problem: Problem?
    private(set) var successMessage: String?
    private(set) var isRefreshingDeletion = false
    private(set) var isRefreshingBackups = false
    private(set) var isDeleting = false
    private(set) var isRetryingDeletion = false
    private(set) var isRestoring = false
    private(set) var pinningBackupID: SkillBackupID?
    private(set) var publishedMutationGeneration: UInt64 = 0
    var restoreDistribution = false

    private var dependencies: SkillLifecycleDependencies?
    private var runtimeReady = false
    private var runtimeBlockMessage = "Preparing the managed library…"
    private var activeSkillID: SkillID?
    private var deletionGeneration: UInt64 = 0
    private var backupGeneration: UInt64 = 0

    var isMutating: Bool {
        isDeleting || isRetryingDeletion || isRestoring || pinningBackupID != nil
    }

    var availableBackupCount: Int {
        backups.lazy.filter { $0.availability == .available }.count
    }

    func activate(dependencies: SkillLifecycleDependencies) {
        self.dependencies = dependencies
        runtimeReady = true
        if case .blocked = deletionState {
            deletionState = activeSkillID == nil ? .empty : .loading
        }
        if case .blocked = backupState {
            backupState = .loading
        }
    }

    func blockRuntime(message: String) {
        runtimeReady = false
        runtimeBlockMessage = message
        dependencies = nil
        deletionGeneration &+= 1
        backupGeneration &+= 1
        deletionState = .blocked(message)
        backupState = .blocked(message)
        isRefreshingDeletion = false
        isRefreshingBackups = false
        if !isMutating {
            pendingDeletion = nil
            pendingRestore = nil
        }
    }

    func refresh(skillID: SkillID?) async {
        await refreshDeletion(skillID: skillID, clearFeedback: true)
        await refreshBackups(clearFeedback: false)
    }

    func refreshCurrent() async {
        await refreshDeletion(skillID: activeSkillID, clearFeedback: true)
        await refreshBackups(clearFeedback: false)
    }

    func refreshBackupsOnly() async {
        await refreshBackups(clearFeedback: true)
    }

    func prepareDeletion() {
        guard !isMutating,
              case .ready(let preview) = deletionState,
              preview.status == .ready,
              preview.token != nil else {
            return
        }
        problem = nil
        successMessage = nil
        deletionResult = nil
        pendingDeletion = PendingDeletion(
            preview: preview,
            operationID: SSOTOperationID(),
            backupID: SkillBackupID()
        )
    }

    func cancelDeletionPreview() {
        guard !isDeleting else { return }
        pendingDeletion = nil
        deletionResult = nil
    }

    func confirmDeletion() async {
        guard !isMutating,
              let pendingDeletion,
              let dependencies else {
            return
        }
        isDeleting = true
        problem = nil
        successMessage = nil
        defer { isDeleting = false }
        do {
            let result = try await dependencies.delete(
                pendingDeletion.preview,
                pendingDeletion.operationID,
                pendingDeletion.backupID
            )
            deletionResult = result
            publishDeletionResult(result)
        } catch {
            if let readback = try? await dependencies.deletionReadback(
                pendingDeletion.operationID
            ) {
                deletionResult = readback
                publishDeletionResult(readback)
            } else {
                problem = Self.problem(for: error)
            }
        }
        await refreshBackups(clearFeedback: false)
    }

    func finishDeletionPresentation() {
        guard !isDeleting else { return }
        if deletionResult != nil {
            publishedMutationGeneration &+= 1
        }
        pendingDeletion = nil
        deletionResult = nil
    }

    func retryDeletion(_ readback: SkillDeletionResult) async {
        guard !isMutating, let dependencies else { return }
        isRetryingDeletion = true
        problem = nil
        successMessage = nil
        defer { isRetryingDeletion = false }
        do {
            let result = try await dependencies.retryDeletion(readback.operationID)
            deletionResult = result
            publishDeletionResult(result)
        } catch {
            deletionResult = try? await dependencies.deletionReadback(readback.operationID)
            problem = Self.problem(for: error)
        }
        await refreshDeletion(skillID: activeSkillID, clearFeedback: false)
        await refreshBackups(clearFeedback: false)
    }

    func setBackupPinned(_ item: SkillBackupCatalogItem, isPinned: Bool) async {
        guard !isMutating,
              item.availability == .available,
              let dependencies else {
            return
        }
        pinningBackupID = item.backupID
        problem = nil
        defer { pinningBackupID = nil }
        do {
            _ = try await dependencies.setBackupPinned(item.backupID, isPinned)
            await refreshBackups(clearFeedback: false)
        } catch {
            problem = Self.problem(for: error)
        }
    }

    func prepareRestore(_ item: SkillBackupCatalogItem) async {
        guard !isMutating,
              item.availability == .available,
              let dependencies else {
            return
        }
        problem = nil
        successMessage = nil
        restoreResult = nil
        do {
            let preview = try await dependencies.restorePreview(item.backupID)
            pendingRestore = PendingRestore(preview: preview)
            restoreDistribution = false
        } catch {
            problem = Self.problem(for: error)
        }
    }

    func cancelRestorePreview() {
        guard !isRestoring else { return }
        pendingRestore = nil
        restoreResult = nil
        restoreDistribution = false
    }

    func confirmRestore() async {
        guard !isMutating,
              let pendingRestore,
              let dependencies else {
            return
        }
        isRestoring = true
        problem = nil
        successMessage = nil
        defer { isRestoring = false }
        do {
            let result = try await dependencies.restore(
                pendingRestore.preview,
                restoreDistribution
            )
            restoreResult = result
            publishRestoreResult(result)
        } catch {
            problem = Self.problem(for: error)
        }
        await refreshBackups(clearFeedback: false)
    }

    func finishRestorePresentation() {
        guard !isRestoring else { return }
        if restoreResult != nil {
            publishedMutationGeneration &+= 1
        }
        pendingRestore = nil
        restoreResult = nil
        restoreDistribution = false
    }

    private func refreshDeletion(
        skillID: SkillID?,
        clearFeedback: Bool
    ) async {
        deletionGeneration &+= 1
        let generation = deletionGeneration
        if !isMutating, skillID != activeSkillID {
            pendingDeletion = nil
            deletionResult = nil
        }
        activeSkillID = skillID
        if clearFeedback {
            problem = nil
            successMessage = nil
        }
        guard let skillID else {
            deletionState = runtimeReady ? .empty : .blocked(runtimeBlockMessage)
            isRefreshingDeletion = false
            return
        }
        guard runtimeReady, let dependencies else {
            deletionState = .blocked(runtimeBlockMessage)
            return
        }
        isRefreshingDeletion = true
        deletionState = .loading
        do {
            let preview = try await dependencies.deletionPreview(skillID)
            guard generation == deletionGeneration, activeSkillID == skillID else { return }
            deletionState = .ready(preview)
        } catch {
            guard generation == deletionGeneration, activeSkillID == skillID else { return }
            deletionState = .failed(Self.problem(for: error))
        }
        if generation == deletionGeneration {
            isRefreshingDeletion = false
        }
    }

    private func refreshBackups(clearFeedback: Bool) async {
        backupGeneration &+= 1
        let generation = backupGeneration
        if clearFeedback {
            problem = nil
            successMessage = nil
        }
        guard runtimeReady, let dependencies else {
            backupState = .blocked(runtimeBlockMessage)
            return
        }
        isRefreshingBackups = true
        backupState = .loading
        do {
            let catalog = try await dependencies.backupCatalog()
            let deletions = try await dependencies.recoverableDeletions()
            guard generation == backupGeneration else { return }
            backups = catalog
            recoverableDeletions = deletions
            backupState = .loaded
        } catch {
            guard generation == backupGeneration else { return }
            backupState = .failed(Self.problem(for: error))
        }
        if generation == backupGeneration {
            isRefreshingBackups = false
        }
    }

    private func publishDeletionResult(_ result: SkillDeletionResult) {
        switch result.status {
        case .completed:
            successMessage = "The Skill was deleted and cleanup completed."
        case .cleanupPending:
            successMessage = "The Skill was deleted. Cleanup still needs to finish."
        case .rolledBack:
            problem = .rolledBack
        case .needsRepair:
            problem = .needsRepair
        case .operationInProgress:
            problem = .operationInProgress
        case .ready:
            problem = .operationDidNotComplete
        }
    }

    private func publishRestoreResult(_ result: SkillRestoreResult) {
        switch result.status {
        case .completed:
            successMessage = "The Skill was restored."
        case .noOp:
            successMessage = "The matching Skill was already restored."
        case .restoredUndistributed:
            problem = .restoredUndistributed
        case .ready:
            problem = .operationDidNotComplete
        }
    }
}
