import Dispatch
import Testing

@testable import SkillsManager

@Suite("Managed Skill update admission", .serialized)
struct ManagedSkillUpdateAdmissionTests {
    @Test("one Skill has one update owner while different Skills remain independent")
    func leasesAreSkillScoped() async throws {
        let admission = ManagedSkillUpdateAdmission()
        let firstSkill = SkillID()
        let secondSkill = SkillID()
        let firstLease = try #require(await admission.acquire(firstSkill))

        #expect(await admission.acquire(firstSkill) == nil)
        let secondLease = try #require(await admission.acquire(secondSkill))
        await admission.release(firstLease)
        let replacementLease = try #require(await admission.acquire(firstSkill))
        await admission.release(firstLease)
        #expect(await admission.acquire(firstSkill) == nil)
        await admission.release(replacementLease)
        await admission.release(secondLease)
    }

    @Test("the single-Skill entry reports a shared batch lease")
    @MainActor
    func singleEntryUsesSharedAdmission() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let admission = ManagedSkillUpdateAdmission()
        let model = SkillUpdateCheckViewModel(admission: admission)
        model.activate(writer: fixture.writer, remote: fixture.remote.client)
        await model.refresh(skillID: fixture.skillID)
        let snapshot = try await fixture.checks.check(fixture.skillID)
        let lease = try #require(await admission.acquire(fixture.skillID))

        await model.prepareUpdate(snapshot)

        #expect(model.pendingUpdate == nil)
        #expect(model.updateProblem == .operationInProgress)
        await admission.release(lease)
    }

    @Test("a prepared single-Skill update blocks batch prepare")
    @MainActor
    func batchEntryUsesSharedAdmission() async throws {
        let fixture = try await makeExecutionFixture(remoteMarkdown: "# Remote")
        defer { fixture.remote.cleanup() }
        let admission = ManagedSkillUpdateAdmission()
        let single = SkillUpdateCheckViewModel(admission: admission)
        single.activate(writer: fixture.writer, remote: fixture.remote.client)
        await single.refresh(skillID: fixture.skillID)
        let snapshot = try await fixture.checks.check(fixture.skillID)
        await single.prepareUpdate(snapshot)
        #expect(single.pendingUpdate != nil)

        let probe = SkillBatchUpdateProbe(snapshots: [fixture.skillID: snapshot])
        let batch = SkillBatchUpdateViewModel(admission: admission)
        batch.activate(dependencies: await probe.dependencies)
        batch.configure([
            .init(skillID: fixture.skillID, displayName: "Demo"),
        ])
        await batch.checkAll()
        batch.select(fixture.skillID, selected: true)
        await batch.executeSelected()

        #expect(batch.items.first?.finalResult == .needsAttention)
        #expect(await probe.prepareCount == 0)
        await single.cancelUpdate()
    }

    @Test("selection changes during confirm keep the shared lease until terminal")
    @MainActor
    func selectionChangeDuringConfirmKeepsLease() async throws {
        let gate = SkillUpdateConfirmationGate()
        var hooks = JournaledSSOTWriterHooks()
        hooks.afterUpdateBackupPublished = gate.reach
        let fixture = try await makeExecutionFixture(
            remoteMarkdown: "# Remote",
            hooks: hooks
        )
        defer { fixture.remote.cleanup() }
        let admission = ManagedSkillUpdateAdmission()
        let releaseGate = SkillBatchUpdateTestGate()
        let single = SkillUpdateCheckViewModel(
            admission: admission,
            afterConfirmAdmissionRelease: { await releaseGate.wait() }
        )
        single.activate(writer: fixture.writer, remote: fixture.remote.client)
        await single.refresh(skillID: fixture.skillID)
        let snapshot = try await fixture.checks.check(fixture.skillID)
        await single.prepareUpdate(snapshot)

        let confirmation = Task { await single.confirmUpdate() }
        await Task.detached { gate.waitUntilReached() }.value
        await single.refresh(skillID: SkillID())

        #expect(await admission.acquire(fixture.skillID) == nil)
        gate.release()
        await releaseGate.waitUntilReached()
        let latestSelection = SkillID()
        await single.refresh(skillID: latestSelection)
        await releaseGate.release()
        await confirmation.value
        #expect(single.activeSkillID == latestSelection)
        let lease = try #require(await admission.acquire(fixture.skillID))
        await admission.release(lease)
    }
}

private final class SkillUpdateConfirmationGate: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func reach(_: SkillBackupID) {
        reached.signal()
        resume.wait()
    }

    func waitUntilReached() {
        reached.wait()
    }

    func release() {
        resume.signal()
    }
}
