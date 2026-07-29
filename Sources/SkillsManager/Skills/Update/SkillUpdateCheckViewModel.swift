import Foundation
import Observation

@MainActor
@Observable final class SkillUpdateCheckViewModel {
    enum LoadState {
        case blocked(String)
        case empty
        case loading
        case loaded(ManagedSkillUpdateCheckSnapshot?)
        case failed(ManagedSkillUpdateCheckProblem)
    }

    private(set) var loadState: LoadState = .blocked("Preparing the managed library…")
    private(set) var activeSkillID: SkillID?
    private(set) var isChecking = false
    private(set) var problem: ManagedSkillUpdateCheckProblem?
    private(set) var pendingUpdate: ManagedSkillUpdateExecutionPreview?
    private(set) var updateSelections: [String: ManagedSkillUpdateCopyDecision] = [:]
    private(set) var isPreparingUpdate = false
    private(set) var isUpdating = false
    private(set) var updateProblem: ManagedSkillUpdateExecutionProblem?
    private(set) var updateResult: ManagedSkillUpdateExecutionStatus?

    private var service: ManagedSkillUpdateCheckService?
    private var updateService: ManagedSkillUpdateExecutionService?
    private let admission: ManagedSkillUpdateAdmission
    private let afterConfirmAdmissionRelease: @MainActor @Sendable () async -> Void
    private var admissionLease: ManagedSkillUpdateAdmissionLease?
    private var hasDeferredRefresh = false
    private var deferredRefreshSkillID: SkillID?
    private var generation: UInt64 = 0
    private var runtimeBlockMessage = "Preparing the managed library…"

    init(
        admission: ManagedSkillUpdateAdmission = ManagedSkillUpdateAdmission(),
        afterConfirmAdmissionRelease:
            @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.admission = admission
        self.afterConfirmAdmissionRelease = afterConfirmAdmissionRelease
    }

    func activate(writer: JournaledSSOTWriter, remote: RemoteSkillClient) {
        guard service == nil, updateService == nil else { return }
        service = ManagedSkillUpdateCheckService(writer: writer, remote: remote)
        updateService = ManagedSkillUpdateExecutionService(writer: writer, remote: remote)
    }

    func blockRuntime(message: String) async {
        let updateOperationActive = isPreparingUpdate || isUpdating
        if !updateOperationActive, let pendingUpdate, let updateService {
            await updateService.cancel(pendingUpdate.token)
        }
        if !updateOperationActive {
            await releaseAdmission()
        }
        service = nil
        updateService = nil
        runtimeBlockMessage = message
        generation &+= 1
        isChecking = false
        if !updateOperationActive {
            pendingUpdate = nil
            updateSelections = [:]
        }
        loadState = .blocked(message)
    }

    func refresh(skillID: SkillID?) async {
        if isUpdating {
            hasDeferredRefresh = true
            deferredRefreshSkillID = skillID
            return
        }
        if let pendingUpdate,
           pendingUpdate.skillID != skillID,
           let updateService {
            await updateService.cancel(pendingUpdate.token)
            self.pendingUpdate = nil
            updateSelections = [:]
            await releaseAdmission()
        }
        generation &+= 1
        let requestGeneration = generation
        isChecking = false
        activeSkillID = skillID
        problem = nil
        updateProblem = nil
        guard let skillID else {
            loadState = service == nil ? .blocked(runtimeBlockMessage) : .empty
            return
        }
        guard let service else {
            loadState = .blocked(runtimeBlockMessage)
            return
        }
        loadState = .loading
        do {
            let snapshot = try await service.load(skillID)
            guard generation == requestGeneration, activeSkillID == skillID else { return }
            loadState = .loaded(snapshot)
        } catch {
            guard generation == requestGeneration, activeSkillID == skillID else { return }
            loadState = .failed(Self.problem(for: error))
        }
    }

    func refreshCurrent() async {
        await refresh(skillID: activeSkillID)
    }

    func checkCurrent() async {
        guard !isChecking, let skillID = activeSkillID, let service else { return }
        isChecking = true
        problem = nil
        let requestGeneration = generation
        do {
            let snapshot = try await service.check(skillID)
            guard generation == requestGeneration, activeSkillID == skillID else { return }
            loadState = .loaded(snapshot)
        } catch {
            guard generation == requestGeneration, activeSkillID == skillID else { return }
            problem = Self.problem(for: error)
        }
        if generation == requestGeneration {
            isChecking = false
        }
    }

    func prepareUpdate(_ snapshot: ManagedSkillUpdateCheckSnapshot) async {
        guard !isPreparingUpdate,
              !isUpdating,
              pendingUpdate == nil,
              admissionLease == nil,
              let updateService else { return }
        guard let lease = await admission.acquire(snapshot.skillID) else {
            updateProblem = .operationInProgress
            return
        }
        admissionLease = lease
        let requestGeneration = generation
        isPreparingUpdate = true
        updateProblem = nil
        updateResult = nil
        updateSelections = [:]
        do {
            let preview = try await updateService.prepare(snapshot)
            guard generation == requestGeneration,
                  activeSkillID == preview.skillID else {
                await updateService.cancel(preview.token)
                await releaseAdmission()
                isPreparingUpdate = false
                return
            }
            pendingUpdate = preview
        } catch {
            updateProblem = Self.updateProblem(for: error)
            await releaseAdmission()
        }
        isPreparingUpdate = false
    }

    func select(
        _ decision: ManagedSkillUpdateCopyDecision,
        scopeKey: String
    ) {
        guard pendingUpdate?.copyChoices.contains(where: { $0.scopeKey == scopeKey }) == true,
              !isUpdating else { return }
        updateSelections[scopeKey] = decision
    }

    var canConfirmUpdate: Bool {
        guard let pendingUpdate, !isUpdating else { return false }
        return Set(updateSelections.keys)
            == Set(pendingUpdate.copyChoices.map(\.scopeKey))
    }

    func confirmUpdate() async {
        guard canConfirmUpdate,
              let pendingUpdate,
              let updateService else { return }
        isUpdating = true
        updateProblem = nil
        var shouldRefresh = false
        var refreshSkillID: SkillID?
        do {
            let selections = pendingUpdate.copyChoices.compactMap { choice in
                updateSelections[choice.scopeKey].map {
                    ManagedSkillUpdateDecisionSelection(
                        scopeKey: choice.scopeKey,
                        decision: $0
                    )
                }
            }
            let result = try await updateService.confirm(
                pendingUpdate.token,
                selections: selections
            )
            self.pendingUpdate = nil
            updateSelections = [:]
            shouldRefresh = true
            refreshSkillID = result.skillID
            updateResult = result.status
        } catch {
            self.pendingUpdate = nil
            updateSelections = [:]
            updateProblem = Self.updateProblem(for: error)
        }
        await releaseAdmission()
        await afterConfirmAdmissionRelease()
        if hasDeferredRefresh {
            shouldRefresh = true
            refreshSkillID = deferredRefreshSkillID
        }
        hasDeferredRefresh = false
        deferredRefreshSkillID = nil
        isUpdating = false
        if shouldRefresh {
            await refresh(skillID: refreshSkillID)
        }
    }

    func cancelUpdate() async {
        guard !isUpdating, let pendingUpdate, let updateService else { return }
        await updateService.cancel(pendingUpdate.token)
        self.pendingUpdate = nil
        updateSelections = [:]
        await releaseAdmission()
    }

    func selectedDecision(
        for scopeKey: String
    ) -> ManagedSkillUpdateCopyDecision? {
        updateSelections[scopeKey]
    }

    private nonisolated static func problem(for error: Error) -> ManagedSkillUpdateCheckProblem {
        if let problem = error as? ManagedSkillUpdateCheckProblem { return problem }
        if error is UpdateCheckStoreError || error is SQLiteStoreError {
            return .databaseUnavailable
        }
        return .failed
    }

    private nonisolated static func updateProblem(
        for error: Error
    ) -> ManagedSkillUpdateExecutionProblem {
        if let problem = error as? ManagedSkillUpdateExecutionProblem { return problem }
        return .failed
    }

    private func releaseAdmission() async {
        guard let admissionLease else { return }
        self.admissionLease = nil
        await admission.release(admissionLease)
    }
}
