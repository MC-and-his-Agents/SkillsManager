import Foundation
import Observation

@MainActor
@Observable final class ManagedLocalImportViewModel {
    private(set) var preview: ManagedLocalImportPreview?
    private(set) var result: ManagedLocalImportResult?
    private(set) var problem: ManagedLocalImportProblem?
    private(set) var isPreparing = false
    private(set) var isExecuting = false

    private var service: ManagedLocalImportService?
    private var generation: UInt64 = 0

    var isWorking: Bool { isPreparing || isExecuting }
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
        service = ManagedLocalImportService(dependencies: .live(writer: writer))
    }

    func prepare(
        candidate: SkillImportWorker.ImportCandidatePayload,
        displayName: String,
        scope: ManagedLocalImportScope
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
            let prepared = try await service.prepare(
                candidate: candidate,
                displayName: displayName,
                scope: scope
            )
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

    func confirm() async {
        guard !isWorking, let preview, let service else { return }
        isExecuting = true
        problem = nil
        defer { isExecuting = false }
        do {
            result = try await service.execute(preview.token)
            self.preview = nil
        } catch let problem as ManagedLocalImportProblem {
            self.problem = problem
        } catch {
            problem = .failed(error.localizedDescription)
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
