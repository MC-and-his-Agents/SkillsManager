import Foundation

@MainActor
final class AppLibraryRuntimeBootstrap {
    private var startupTask: Task<Void, Never>?

    func start(
        using startup: @escaping @Sendable () async -> LibraryStartupResult,
        runtimeState: LibraryRuntimeState,
        customPathStore: CustomPathStore,
        skillStore: SkillStore
    ) async {
        if let startupTask {
            await startupTask.value
            return
        }

        let task = Task { @MainActor in
            let result = await startup()
            guard result.readiness == .ready, let session = result.session else {
                runtimeState.apply(result)
                return
            }

            do {
                try await customPathStore.activate(using: session)
                skillStore.activatePersistence(session)
                runtimeState.apply(result)
                await skillStore.loadSkills()
            } catch {
                runtimeState.apply(LibraryStartupResult(
                    phase: .running,
                    readiness: .blocked,
                    diagnostics: [.make(
                        .unrecoverable,
                        subjectKind: .database,
                        subjectID: "persistenceActivation"
                    )],
                    outcome: result.outcome,
                    session: nil
                ))
            }
        }
        startupTask = task
        await task.value
    }
}
