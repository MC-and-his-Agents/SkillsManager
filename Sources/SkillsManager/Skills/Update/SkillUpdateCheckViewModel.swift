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

    private var service: ManagedSkillUpdateCheckService?
    private var generation: UInt64 = 0
    private var runtimeBlockMessage = "Preparing the managed library…"

    func activate(writer: JournaledSSOTWriter, remote: RemoteSkillClient) {
        service = ManagedSkillUpdateCheckService(writer: writer, remote: remote)
    }

    func blockRuntime(message: String) {
        service = nil
        runtimeBlockMessage = message
        generation &+= 1
        isChecking = false
        loadState = .blocked(message)
    }

    func refresh(skillID: SkillID?) async {
        generation &+= 1
        let requestGeneration = generation
        isChecking = false
        activeSkillID = skillID
        problem = nil
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

    private nonisolated static func problem(for error: Error) -> ManagedSkillUpdateCheckProblem {
        if let problem = error as? ManagedSkillUpdateCheckProblem { return problem }
        if error is UpdateCheckStoreError || error is SQLiteStoreError {
            return .databaseUnavailable
        }
        return .failed
    }
}
