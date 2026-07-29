import Testing

@testable import SkillsManager

@Suite("Skill batch update result mapping")
@MainActor
struct SkillBatchUpdateMappingTests {
    @Test("every check problem has a stable terminal category")
    func checkProblems() {
        let problems: [(ManagedSkillUpdateCheckProblem, SkillBatchUpdateResult)] = [
            (.unavailable, .needsAttention),
            (.stale, .conflict),
            (.cancelled, .cancelled),
            (.timeout, .failed),
            (.offline, .failed),
            (.rateLimited, .failed),
            (.providerUnavailable, .failed),
            (.unsafeContent, .failed),
            (.databaseUnavailable, .failed),
            (.failed, .failed),
        ]
        let model = configuredModel(count: problems.count)

        for (index, entry) in problems.enumerated() {
            model.applyCheckError(entry.0, at: index)
        }

        #expect(model.items.map(\.finalResult) == problems.map(\.1))
        #expect(model.summary.isComplete)
    }

    @Test("every execution status has a stable terminal category")
    func executionStatuses() {
        let statuses: [(ManagedSkillUpdateExecutionStatus, SkillBatchUpdateResult)] = [
            (.cancelled, .cancelled),
            (.noChange, .upToDate),
            (.backupReadyUpdateNotStarted, .needsAttention),
            (.copyDecisionsAppliedUpdateNotCompleted, .needsAttention),
            (.updated, .updated),
            (.updatedNeedsAttention, .needsAttention),
            (.updateRolledBack, .failed),
            (.updateIndeterminate, .needsAttention),
            (.needsRepair, .needsAttention),
        ]
        let model = configuredModel(count: statuses.count)

        for (index, entry) in statuses.enumerated() {
            model.apply(
                ManagedSkillUpdateExecutionResult(
                    skillID: model.items[index].skillID,
                    status: entry.0,
                    backupID: nil
                ),
                hadForkDecision: false,
                for: model.items[index].skillID
            )
        }

        #expect(model.items.map(\.finalResult) == statuses.map(\.1))
        #expect(model.summary.isComplete)
    }

    @Test("every execution problem has a stable terminal category")
    func executionProblems() {
        let problems: [(ManagedSkillUpdateExecutionProblem, SkillBatchUpdateResult)] = [
            (.unavailable, .needsAttention),
            (.noUpdate, .upToDate),
            (.stale, .conflict),
            (.invalidDecisions, .needsAttention),
            (.unsafeCopyState, .needsAttention),
            (.operationInProgress, .needsAttention),
            (.permissionDenied, .needsAttention),
            (.providerUnavailable, .failed),
            (.needsRepair, .needsAttention),
            (.failed, .failed),
        ]
        let model = configuredModel(count: problems.count)

        for (index, entry) in problems.enumerated() {
            model.applyExecutionError(entry.0, for: model.items[index].skillID)
        }

        #expect(model.items.map(\.finalResult) == problems.map(\.1))
        #expect(model.summary.isComplete)
    }

    @Test("presentation exposes text and VoiceOver values for every state")
    func presentationContract() {
        let skillID = SkillID()
        let phases: [SkillBatchUpdateItemPhase] = [
            .queued, .checking, .ready, .decisionRequired, .preparing, .updating,
        ] + SkillBatchUpdateResult.allCases.map { .result($0, nil) }

        for phase in phases {
            let row = SkillBatchUpdatePresentation.row(for: SkillBatchUpdateItem(
                skillID: skillID,
                displayName: "Demo",
                phase: phase
            ))
            #expect(!row.title.isEmpty)
            #expect(!row.systemImage.isEmpty)
            #expect(row.accessibilityValue.contains("Demo"))
        }
        #expect(SkillBatchUpdatePresentation.controls(
            state: .checking,
            itemCount: 1,
            selectedCount: 0,
            selectionsComplete: true
        ).canStop)
        #expect(!SkillBatchUpdatePresentation.controls(
            state: .blocked("Unavailable"),
            itemCount: 1,
            selectedCount: 1,
            selectionsComplete: true
        ).canUpdate)
    }

    private func configuredModel(count: Int) -> SkillBatchUpdateViewModel {
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: SkillBatchUpdateDependencies(
            check: { _ in throw ManagedSkillUpdateCheckProblem.failed },
            prepare: { _ in throw ManagedSkillUpdateExecutionProblem.failed },
            cancel: { _ in },
            confirm: { _, _ in throw ManagedSkillUpdateExecutionProblem.failed }
        ))
        model.configure((0..<count).map {
            SkillBatchUpdateCatalogItem(
                skillID: SkillID(),
                displayName: "Skill \($0)"
            )
        })
        return model
    }
}
