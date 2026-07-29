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
    private var generation: UInt64 = 0
    private var runtimeBlockMessage = "Preparing the managed library…"

    func activate(writer: JournaledSSOTWriter, remote: RemoteSkillClient) {
        service = ManagedSkillUpdateCheckService(writer: writer, remote: remote)
        updateService = ManagedSkillUpdateExecutionService(writer: writer, remote: remote)
    }

    func blockRuntime(message: String) async {
        if let pendingUpdate, let updateService {
            await updateService.cancel(pendingUpdate.token)
        }
        service = nil
        updateService = nil
        runtimeBlockMessage = message
        generation &+= 1
        isChecking = false
        isPreparingUpdate = false
        isUpdating = false
        pendingUpdate = nil
        updateSelections = [:]
        loadState = .blocked(message)
    }

    func refresh(skillID: SkillID?) async {
        if let pendingUpdate,
           pendingUpdate.skillID != skillID,
           let updateService {
            await updateService.cancel(pendingUpdate.token)
            self.pendingUpdate = nil
            updateSelections = [:]
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
        guard !isPreparingUpdate, !isUpdating, let updateService else { return }
        isPreparingUpdate = true
        updateProblem = nil
        updateResult = nil
        if let pendingUpdate {
            await updateService.cancel(pendingUpdate.token)
        }
        pendingUpdate = nil
        updateSelections = [:]
        do {
            let preview = try await updateService.prepare(snapshot)
            guard activeSkillID == preview.skillID else {
                await updateService.cancel(preview.token)
                isPreparingUpdate = false
                return
            }
            pendingUpdate = preview
        } catch {
            updateProblem = Self.updateProblem(for: error)
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
            await refresh(skillID: result.skillID)
            updateResult = result.status
        } catch {
            updateProblem = Self.updateProblem(for: error)
        }
        isUpdating = false
    }

    func cancelUpdate() async {
        guard !isUpdating, let pendingUpdate, let updateService else { return }
        await updateService.cancel(pendingUpdate.token)
        self.pendingUpdate = nil
        updateSelections = [:]
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
}
