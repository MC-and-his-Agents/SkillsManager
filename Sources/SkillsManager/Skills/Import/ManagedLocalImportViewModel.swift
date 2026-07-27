import Foundation
import Observation

@MainActor
@Observable final class ManagedLocalImportViewModel {
    private(set) var preview: ManagedLocalImportPreview?
    private(set) var result: ManagedLocalImportResult?
    private(set) var problem: ManagedLocalImportProblem?
    private(set) var isPreparing = false
    private(set) var isExecuting = false
    private(set) var isFinalizing = false

    private var service: ManagedInstallService?
    private var generation: UInt64 = 0

    var isWorking: Bool { isPreparing || isExecuting || isFinalizing }
    var isAvailable: Bool { service != nil }

    func activate(writer: JournaledSSOTWriter?) {
        generation &+= 1
        preview = nil
        result = nil
        problem = nil
        guard let writer else {
            service = nil
            problem = .failed("The managed library session is unavailable.")
            return
        }
        activate(dependencies: .live(writer: writer))
    }

    func activate(dependencies: ManagedInstallDependencies) {
        service = ManagedInstallService(dependencies: dependencies)
    }

    func prepare(
        candidate: SkillImportWorker.ImportCandidatePayload,
        displayName: String,
        scope: ManagedLocalImportScope
    ) async {
        await prepare { service in
            try await service.prepare(
                candidate: candidate,
                displayName: displayName,
                scope: scope
            )
        }
    }

    func prepareClawdhub(
        candidate: SkillImportWorker.ImportCandidatePayload,
        skill: RemoteSkill,
        scope: ManagedLocalImportScope
    ) async {
        await prepare { service in
            try await service.prepareClawdhub(
                candidate: candidate,
                skill: skill,
                scope: scope
            )
        }
    }

    private func prepare(
        operation: (ManagedInstallService) async throws -> ManagedLocalImportPreview
    ) async {
        guard !isWorking, let service else {
            if service == nil {
                problem = .failed("The managed library session is unavailable.")
            }
            return
        }
        generation &+= 1
        let currentGeneration = generation
        isPreparing = true
        preview = nil
        result = nil
        problem = nil
        defer {
            if generation == currentGeneration {
                isPreparing = false
            }
        }
        do {
            let prepared = try await operation(service)
            guard generation == currentGeneration else { return }
            preview = prepared
        } catch let problem as ManagedLocalImportProblem {
            guard generation == currentGeneration else { return }
            self.problem = problem
        } catch {
            guard generation == currentGeneration else { return }
            problem = .failed(error.localizedDescription)
        }
    }

    func confirm(finalize: @MainActor () async -> Void = {}) async {
        guard !isWorking, let preview, let service else { return }
        isExecuting = true
        problem = nil
        do {
            result = try await service.execute(preview.token)
            self.preview = nil
            isFinalizing = true
            isExecuting = false
            await finalize()
            isFinalizing = false
        } catch let problem as ManagedLocalImportProblem {
            self.problem = problem
            isExecuting = false
        } catch {
            problem = .failed(error.localizedDescription)
            isExecuting = false
        }
    }

    func cancelPreview() {
        guard !isExecuting else { return }
        generation &+= 1
        preview = nil
    }

    func reset() {
        guard !isWorking else { return }
        generation &+= 1
        preview = nil
        result = nil
        problem = nil
    }
}
