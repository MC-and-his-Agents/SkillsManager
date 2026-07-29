import Testing

@testable import SkillsManager

@Suite("Skill batch update", .serialized)
@MainActor
struct SkillBatchUpdateViewModelTests {
    @Test("checks every managed Skill sequentially and classifies all check states")
    func checksAndClassifiesCatalog() async throws {
        let entries = [
            ("F", ManagedSkillUpdateCheckStatus.conflict, nil),
            ("C", .copyDrift, DistributionCopyObservationState.contentDrift),
            ("A", .upToDate, nil),
            ("B", .remoteChanged, nil),
            ("D", .localModified, nil),
            ("E", .capabilityUnavailable, nil),
        ]
        var catalog: [SkillBatchUpdateCatalogItem] = []
        var snapshots: [SkillID: ManagedSkillUpdateCheckSnapshot] = [:]
        for (name, status, copyState) in entries {
            let skillID = SkillID()
            catalog.append(.init(skillID: skillID, displayName: name))
            snapshots[skillID] = try skillBatchSnapshot(
                skillID: skillID,
                status: status,
                copyState: copyState,
                capabilityReason: "No provider"
            )
        }
        let probe = SkillBatchUpdateProbe(snapshots: snapshots)
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: await probe.dependencies)
        model.configure(catalog.reversed())

        await model.checkAll()

        #expect(model.state == .review)
        #expect(await probe.maximumConcurrentChecks == 1)
        #expect(await probe.checkOrder == model.items.map(\.skillID))
        #expect(model.items.map(\.displayName) == ["A", "B", "C", "D", "E", "F"])
        #expect(model.items.map(\.phase) == [
            .result(.upToDate, nil),
            .ready,
            .decisionRequired,
            .result(.conflict, "The managed SSOT content was modified locally."),
            .result(.needsAttention, "No provider"),
            .result(.conflict, "The managed or distributed state changed."),
        ])
        #expect(model.summary.completed == 4)
        #expect(model.summary.total == 6)
    }

    @Test("safe selected updates complete while unselected work is skipped")
    func executesSelectionsAndDecisions() async throws {
        let readyID = SkillID()
        let copyID = SkillID()
        let skippedID = SkillID()
        let snapshots = [
            readyID: try skillBatchSnapshot(skillID: readyID, status: .remoteChanged),
            copyID: try skillBatchSnapshot(
                skillID: copyID,
                status: .copyDrift,
                copyState: .contentDrift
            ),
            skippedID: try skillBatchSnapshot(skillID: skippedID, status: .remoteChanged),
        ]
        let probe = SkillBatchUpdateProbe(snapshots: snapshots)
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: await probe.dependencies)
        model.configure([
            .init(skillID: readyID, displayName: "A"),
            .init(skillID: copyID, displayName: "B"),
            .init(skillID: skippedID, displayName: "C"),
        ])
        await model.checkAll()
        model.select(readyID, selected: true)
        model.select(copyID, selected: true)
        model.choose(.fork, skillID: copyID, scopeKey: "global")

        await model.executeSelected()

        #expect(model.state == .completed)
        #expect(model.items.map(\.finalResult) == [.updated, .forked, .skipped])
        #expect(model.summary.isComplete)
        #expect(await probe.prepareCount == 2)
        #expect(await probe.confirmCount == 2)
    }

    @Test("unsafe Copy drift never enters the write path")
    func unsafeCopyDriftFailsClosed() async throws {
        let skillID = SkillID()
        let snapshot = try skillBatchSnapshot(
            skillID: skillID,
            status: .copyDrift,
            copyState: .physicalDrift
        )
        let probe = SkillBatchUpdateProbe(snapshots: [skillID: snapshot])
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: await probe.dependencies)
        model.configure([.init(skillID: skillID, displayName: "Demo")])

        await model.checkAll()

        #expect(model.state == .completed)
        #expect(model.items.first?.finalResult == .needsAttention)
        #expect(await probe.prepareCount == 0)
    }

    @Test("Stop finishes the active check and cancels queued work")
    func stopsBetweenChecks() async throws {
        let firstID = SkillID()
        let secondID = SkillID()
        let gate = SkillBatchUpdateTestGate()
        let probe = SkillBatchUpdateProbe(
            snapshots: [
                firstID: try skillBatchSnapshot(skillID: firstID, status: .upToDate),
                secondID: try skillBatchSnapshot(skillID: secondID, status: .upToDate),
            ],
            gatedCheckID: firstID,
            checkGate: gate
        )
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: await probe.dependencies)
        model.configure([
            .init(skillID: firstID, displayName: "A"),
            .init(skillID: secondID, displayName: "B"),
        ])

        let task = Task { await model.checkAll() }
        await gate.waitUntilReached()
        model.stop()
        await gate.release()
        await task.value

        #expect(model.items.map(\.finalResult) == [.upToDate, .cancelled])
        #expect(await probe.checkOrder == [firstID])
    }

    @Test("Stop after prepare cancels the preview without confirming")
    func stopsBeforeConfirmation() async throws {
        let skillID = SkillID()
        let gate = SkillBatchUpdateTestGate()
        let probe = SkillBatchUpdateProbe(
            snapshots: [
                skillID: try skillBatchSnapshot(skillID: skillID, status: .remoteChanged),
            ],
            prepareGate: gate
        )
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: await probe.dependencies)
        model.configure([.init(skillID: skillID, displayName: "A")])
        await model.checkAll()
        model.select(skillID, selected: true)

        let task = Task { await model.executeSelected() }
        await gate.waitUntilReached()
        model.stop()
        await gate.release()
        await task.value

        #expect(model.items.first?.finalResult == .cancelled)
        #expect(await probe.cancelCount == 1)
        #expect(await probe.confirmCount == 0)
    }

    @Test("Stop during confirmation waits for the current terminal result")
    func stopsAfterConfirmationStarts() async throws {
        let firstID = SkillID()
        let secondID = SkillID()
        let gate = SkillBatchUpdateTestGate()
        let probe = SkillBatchUpdateProbe(
            snapshots: [
                firstID: try skillBatchSnapshot(skillID: firstID, status: .remoteChanged),
                secondID: try skillBatchSnapshot(skillID: secondID, status: .remoteChanged),
            ],
            confirmGate: gate
        )
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: await probe.dependencies)
        model.configure([
            .init(skillID: firstID, displayName: "A"),
            .init(skillID: secondID, displayName: "B"),
        ])
        await model.checkAll()
        model.select(firstID, selected: true)
        model.select(secondID, selected: true)

        let task = Task { await model.executeSelected() }
        await gate.waitUntilReached()
        model.stop()
        await gate.release()
        await task.value

        #expect(model.items.map(\.finalResult) == [.updated, .cancelled])
        #expect(await probe.confirmCount == 1)
        #expect(await probe.cancelCount == 0)
    }

    @Test("Retry always performs a fresh update check")
    func retryChecksAgain() async throws {
        let skillID = SkillID()
        let snapshot = try skillBatchSnapshot(skillID: skillID, status: .remoteChanged)
        let probe = SkillBatchRetryProbe(snapshot: snapshot)
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: SkillBatchUpdateDependencies(
            check: { try await probe.check($0) },
            prepare: { _ in throw ManagedSkillUpdateExecutionProblem.failed },
            cancel: { _ in },
            confirm: { _, _ in throw ManagedSkillUpdateExecutionProblem.failed }
        ))
        model.configure([.init(skillID: skillID, displayName: "A")])
        await model.checkAll()
        #expect(model.items.first?.finalResult == .failed)

        await model.retry(skillID)

        #expect(model.state == .review)
        #expect(model.items.first?.phase == .ready)
        #expect(await probe.checkCount == 2)
    }

    @Test("a shared lease blocks batch prepare without a write")
    func sharedAdmissionBlocksBatch() async throws {
        let admission = ManagedSkillUpdateAdmission()
        let skillID = SkillID()
        let snapshot = try skillBatchSnapshot(skillID: skillID, status: .remoteChanged)
        let probe = SkillBatchUpdateProbe(snapshots: [skillID: snapshot])
        let model = SkillBatchUpdateViewModel(admission: admission)
        model.activate(dependencies: await probe.dependencies)
        model.configure([.init(skillID: skillID, displayName: "A")])
        await model.checkAll()
        model.select(skillID, selected: true)
        let lease = try #require(await admission.acquire(skillID))

        await model.executeSelected()

        #expect(model.items.first?.finalResult == .needsAttention)
        #expect(await probe.prepareCount == 0)
        await admission.release(lease)
    }

    @Test("duplicate identities fail closed before checking")
    func duplicateIdentityFailsClosed() async {
        let skillID = SkillID()
        let model = SkillBatchUpdateViewModel()
        model.activate(dependencies: SkillBatchUpdateDependencies(
            check: { _ in throw ManagedSkillUpdateCheckProblem.failed },
            prepare: { _ in throw ManagedSkillUpdateExecutionProblem.failed },
            cancel: { _ in },
            confirm: { _, _ in throw ManagedSkillUpdateExecutionProblem.failed }
        ))

        model.configure([
            .init(skillID: skillID, displayName: "A"),
            .init(skillID: skillID, displayName: "B"),
        ])

        guard case .blocked = model.state else {
            Issue.record("Duplicate Skill identity was not blocked.")
            return
        }
        #expect(model.items.isEmpty)
    }
}
