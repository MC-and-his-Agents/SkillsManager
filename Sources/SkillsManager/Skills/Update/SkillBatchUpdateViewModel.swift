import Foundation
import Observation

@MainActor
@Observable final class SkillBatchUpdateViewModel {
    private(set) var state: SkillBatchUpdateRunState =
        .blocked("Preparing the managed library…")
    var items: [SkillBatchUpdateItem] = []
    private(set) var stopRequested = false
    private(set) var operationActive = false

    private let admission: ManagedSkillUpdateAdmission
    private var dependencies: SkillBatchUpdateDependencies?
    private var pendingBlockMessage: String?
    private var generation: UInt64 = 0

    init(admission: ManagedSkillUpdateAdmission = ManagedSkillUpdateAdmission()) {
        self.admission = admission
    }

    var summary: SkillBatchUpdateSummary {
        SkillBatchUpdateSummary(items: items)
    }

    var selectedCount: Int {
        items.count(where: \.isSelected)
    }

    var selectionsComplete: Bool {
        items.filter(\.isSelected).allSatisfy(\.hasCompleteDecisions)
    }

    var controls: SkillBatchUpdatePresentation.Controls {
        SkillBatchUpdatePresentation.controls(
            state: state,
            itemCount: items.count,
            selectedCount: selectedCount,
            selectionsComplete: selectionsComplete
        )
    }

    func activate(writer: JournaledSSOTWriter, remote: RemoteSkillClient) {
        guard dependencies == nil else { return }
        dependencies = .live(writer: writer, remote: remote)
        pendingBlockMessage = nil
        state = items.isEmpty ? .empty : .idle
    }

    func activate(dependencies: SkillBatchUpdateDependencies) {
        guard self.dependencies == nil else { return }
        self.dependencies = dependencies
        pendingBlockMessage = nil
        state = items.isEmpty ? .empty : .idle
    }

    func blockRuntime(message: String) {
        dependencies = nil
        stopRequested = true
        if operationActive {
            pendingBlockMessage = message
        } else {
            pendingBlockMessage = nil
            generation &+= 1
            state = .blocked(message)
        }
    }

    func configure(_ catalog: [SkillBatchUpdateCatalogItem]) {
        guard !operationActive else { return }
        generation &+= 1
        stopRequested = false
        let ids = catalog.map(\.skillID)
        guard Set(ids).count == ids.count else {
            items = []
            state = .blocked("The managed catalog contains a duplicate Skill identity.")
            return
        }
        items = catalog.sorted(by: Self.catalogItemPrecedes).map {
            SkillBatchUpdateItem(skillID: $0.skillID, displayName: $0.displayName)
        }
        if dependencies == nil {
            state = .blocked("The managed library session is unavailable.")
        } else {
            state = items.isEmpty ? .empty : .idle
        }
    }

    func checkAll() async {
        guard !operationActive, let dependencies, !items.isEmpty else { return }
        generation &+= 1
        let requestGeneration = generation
        operationActive = true
        stopRequested = false
        pendingBlockMessage = nil
        resetItems()
        state = .checking

        for index in items.indices {
            if stopRequested {
                cancelQueuedItems(startingAt: index)
                break
            }
            items[index].phase = .checking
            do {
                let snapshot = try await dependencies.check(items[index].skillID)
                guard generation == requestGeneration else { break }
                apply(snapshot, at: index)
            } catch {
                guard generation == requestGeneration else { break }
                applyCheckError(error, at: index)
            }
        }
        finishOperation(reviewWhenActionable: true)
    }

    func select(_ skillID: SkillID, selected: Bool) {
        guard !operationActive,
              let index = index(of: skillID),
              items[index].isActionable else { return }
        items[index].isSelected = selected
    }

    func selectReady() {
        guard state == .review, !operationActive else { return }
        for index in items.indices {
            items[index].isSelected = items[index].phase == .ready
        }
    }

    func choose(
        _ decision: ManagedSkillUpdateCopyDecision,
        skillID: SkillID,
        scopeKey: String
    ) {
        guard !operationActive,
              let index = index(of: skillID),
              items[index].phase == .decisionRequired,
              items[index].scopes.contains(where: { $0.scopeKey == scopeKey }) else {
            return
        }
        items[index].decisions[scopeKey] = decision
    }

    func executeSelected() async {
        guard !operationActive,
              controls.canUpdate,
              let dependencies else { return }
        generation &+= 1
        operationActive = true
        stopRequested = false
        pendingBlockMessage = nil
        state = .executing

        let selectedIDs = items.filter(\.isSelected).map(\.skillID)
        finalizeUnselectedActionableItems()
        for (offset, skillID) in selectedIDs.enumerated() {
            if stopRequested {
                cancelSelectedItems(selectedIDs.dropFirst(offset))
                break
            }
            await execute(skillID, dependencies: dependencies)
        }
        finishOperation(reviewWhenActionable: false)
    }

    func retry(_ skillID: SkillID) async {
        guard !operationActive,
              let dependencies,
              let index = index(of: skillID),
              items[index].allowsRetry else { return }
        generation &+= 1
        let requestGeneration = generation
        operationActive = true
        stopRequested = false
        pendingBlockMessage = nil
        resetItem(at: index)
        items[index].phase = .checking
        state = .checking
        do {
            let snapshot = try await dependencies.check(skillID)
            guard generation == requestGeneration else {
                finishOperation(reviewWhenActionable: true)
                return
            }
            apply(snapshot, at: index)
        } catch {
            guard generation == requestGeneration else {
                finishOperation(reviewWhenActionable: true)
                return
            }
            applyCheckError(error, at: index)
        }
        finishOperation(reviewWhenActionable: true)
    }

    func stop() {
        guard operationActive else { return }
        stopRequested = true
    }

    func selectedDecision(
        skillID: SkillID,
        scopeKey: String
    ) -> ManagedSkillUpdateCopyDecision? {
        index(of: skillID).flatMap { items[$0].decisions[scopeKey] }
    }

    private func execute(
        _ skillID: SkillID,
        dependencies: SkillBatchUpdateDependencies
    ) async {
        guard let index = index(of: skillID),
              let snapshot = items[index].snapshot else {
            setResult(.conflict, detail: "The update check is no longer available.", for: skillID)
            return
        }
        if items[index].decisions.values.contains(.cancel) {
            setResult(.cancelled, detail: nil, for: skillID)
            return
        }
        guard let lease = await admission.acquire(skillID) else {
            setResult(
                .needsAttention,
                detail: ManagedSkillUpdateExecutionProblem.operationInProgress
                    .localizedDescription,
                for: skillID
            )
            return
        }
        items[index].phase = .preparing
        do {
            let preview = try await dependencies.prepare(snapshot)
            guard approvedScopesMatch(preview, item: items[index]) else {
                await dependencies.cancel(preview.token)
                setResult(
                    .conflict,
                    detail: "The Copy targets changed. Check this Skill again.",
                    for: skillID
                )
                await admission.release(lease)
                return
            }
            if stopRequested {
                await dependencies.cancel(preview.token)
                setResult(.cancelled, detail: nil, for: skillID)
                await admission.release(lease)
                return
            }
            items[index].phase = .updating
            let selections = preview.copyChoices.compactMap { choice in
                items[index].decisions[choice.scopeKey].map {
                    ManagedSkillUpdateDecisionSelection(
                        scopeKey: choice.scopeKey,
                        decision: $0
                    )
                }
            }
            let result = try await dependencies.confirm(preview.token, selections)
            apply(
                result,
                hadForkDecision: selections.contains(where: { $0.decision == .fork }),
                for: skillID
            )
        } catch {
            applyExecutionError(error, for: skillID)
        }
        await admission.release(lease)
    }

    private func finishOperation(reviewWhenActionable: Bool) {
        operationActive = false
        stopRequested = false
        if let pendingBlockMessage {
            self.pendingBlockMessage = nil
            state = .blocked(pendingBlockMessage)
        } else if reviewWhenActionable && items.contains(where: \.isActionable) {
            state = .review
        } else {
            state = summary.isComplete ? .completed : .review
        }
    }

    private func resetItems() {
        for index in items.indices { resetItem(at: index) }
    }

    private func resetItem(at index: Int) {
        items[index].phase = .queued
        items[index].snapshot = nil
        items[index].scopes = []
        items[index].decisions = [:]
        items[index].isSelected = false
    }

    private func finalizeUnselectedActionableItems() {
        for index in items.indices
        where items[index].isActionable && !items[index].isSelected {
            setResult(.skipped, detail: nil, at: index)
        }
    }

    private func cancelQueuedItems(startingAt start: Int) {
        guard start < items.endIndex else { return }
        for index in start..<items.endIndex where items[index].phase == .queued {
            setResult(.cancelled, detail: nil, at: index)
        }
    }

    private func cancelSelectedItems<S: Sequence>(_ skillIDs: S)
    where S.Element == SkillID {
        for skillID in skillIDs {
            guard let index = index(of: skillID), items[index].finalResult == nil else {
                continue
            }
            setResult(.cancelled, detail: nil, at: index)
        }
    }

    func setResult(
        _ result: SkillBatchUpdateResult,
        detail: String?,
        for skillID: SkillID
    ) {
        guard let index = index(of: skillID) else { return }
        setResult(result, detail: detail, at: index)
    }

    func setResult(
        _ result: SkillBatchUpdateResult,
        detail: String?,
        at index: Int
    ) {
        items[index].phase = .result(result, detail)
        items[index].isSelected = false
        items[index].decisions = [:]
    }

    private func index(of skillID: SkillID) -> Int? {
        items.firstIndex(where: { $0.skillID == skillID })
    }

    private func approvedScopesMatch(
        _ preview: ManagedSkillUpdateExecutionPreview,
        item: SkillBatchUpdateItem
    ) -> Bool {
        let actual = preview.copyChoices.map(\.scopeKey)
        let expected = item.scopes.map(\.scopeKey)
        return Set(actual).count == actual.count
            && Set(actual) == Set(expected)
    }

    private static func catalogItemPrecedes(
        _ lhs: SkillBatchUpdateCatalogItem,
        _ rhs: SkillBatchUpdateCatalogItem
    ) -> Bool {
        if lhs.displayName != rhs.displayName {
            return lhs.displayName.utf8.lexicographicallyPrecedes(rhs.displayName.utf8)
        }
        return lhs.skillID.directoryName.utf8.lexicographicallyPrecedes(
            rhs.skillID.directoryName.utf8
        )
    }
}
