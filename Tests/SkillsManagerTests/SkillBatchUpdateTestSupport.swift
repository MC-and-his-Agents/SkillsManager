import Foundation
import Testing

@testable import SkillsManager

actor SkillBatchUpdateTestGate {
    private var open = false
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        reached = true
        reachedWaiters.forEach { $0.resume() }
        reachedWaiters = []
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

actor SkillBatchUpdateProbe {
    private let snapshots: [SkillID: ManagedSkillUpdateCheckSnapshot]
    private let gatedCheckID: SkillID?
    private let checkGate: SkillBatchUpdateTestGate?
    private let prepareGate: SkillBatchUpdateTestGate?
    private let confirmGate: SkillBatchUpdateTestGate?
    private(set) var checkOrder: [SkillID] = []
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0
    private(set) var confirmCount = 0
    private(set) var maximumConcurrentChecks = 0
    private var concurrentChecks = 0

    init(
        snapshots: [SkillID: ManagedSkillUpdateCheckSnapshot],
        gatedCheckID: SkillID? = nil,
        checkGate: SkillBatchUpdateTestGate? = nil,
        prepareGate: SkillBatchUpdateTestGate? = nil,
        confirmGate: SkillBatchUpdateTestGate? = nil
    ) {
        self.snapshots = snapshots
        self.gatedCheckID = gatedCheckID
        self.checkGate = checkGate
        self.prepareGate = prepareGate
        self.confirmGate = confirmGate
    }

    func check(_ skillID: SkillID) async throws -> ManagedSkillUpdateCheckSnapshot {
        concurrentChecks += 1
        maximumConcurrentChecks = max(maximumConcurrentChecks, concurrentChecks)
        checkOrder.append(skillID)
        if skillID == gatedCheckID {
            await checkGate?.wait()
        }
        concurrentChecks -= 1
        guard let snapshot = snapshots[skillID] else {
            throw ManagedSkillUpdateCheckProblem.unavailable
        }
        return snapshot
    }

    func prepare(
        _ snapshot: ManagedSkillUpdateCheckSnapshot
    ) async throws -> ManagedSkillUpdateExecutionPreview {
        prepareCount += 1
        await prepareGate?.wait()
        return try skillBatchPreview(snapshot)
    }

    func cancel(_: ManagedSkillUpdateExecutionToken) {
        cancelCount += 1
    }

    func confirm(
        _ token: ManagedSkillUpdateExecutionToken,
        selections: [ManagedSkillUpdateDecisionSelection]
    ) async throws -> ManagedSkillUpdateExecutionResult {
        _ = token
        _ = selections
        confirmCount += 1
        await confirmGate?.wait()
        let skillID = try #require(
            snapshots.values.first(where: { $0.candidate != nil })
        ).skillID
        return ManagedSkillUpdateExecutionResult(
            skillID: skillID,
            status: .updated,
            backupID: nil
        )
    }

    var dependencies: SkillBatchUpdateDependencies {
        SkillBatchUpdateDependencies(
            check: { [self] in try await check($0) },
            prepare: { [self] in try await prepare($0) },
            cancel: { [self] in await cancel($0) },
            confirm: { [self] in try await confirm($0, selections: $1) }
        )
    }
}

actor SkillBatchRetryProbe {
    private let snapshot: ManagedSkillUpdateCheckSnapshot
    private(set) var checkCount = 0

    init(snapshot: ManagedSkillUpdateCheckSnapshot) {
        self.snapshot = snapshot
    }

    func check(_: SkillID) throws -> ManagedSkillUpdateCheckSnapshot {
        checkCount += 1
        if checkCount == 1 {
            throw ManagedSkillUpdateCheckProblem.offline
        }
        return snapshot
    }
}

func skillBatchFingerprint(_ byte: UInt8) throws -> SkillContentFingerprint {
    try SkillContentFingerprint(
        algorithmVersion: 1,
        digest: Data(repeating: byte, count: 32)
    )
}

func skillBatchSnapshot(
    skillID: SkillID,
    status: ManagedSkillUpdateCheckStatus,
    copyState: DistributionCopyObservationState? = nil,
    capabilityReason: String? = nil
) throws -> ManagedSkillUpdateCheckSnapshot {
    let live = try skillBatchFingerprint(1)
    let remote = try skillBatchFingerprint(status == .upToDate ? 1 : 2)
    let candidate: ManagedSkillUpdateCandidate? =
        status == .capabilityUnavailable
            ? nil
            : ManagedSkillUpdateCandidate(
                locator: .clawdhub(
                    slug: "demo",
                    version: try SourceVersion("2.0.0")
                ),
                contentFingerprint: remote
            )
    let copyStates = try copyState.map {
        [
            ManagedSkillUpdateCopyState(
                scopeKey: "global",
                state: $0,
                baselineFingerprint: live,
                observedFingerprint: try skillBatchFingerprint(3),
                baselineTreeDigest: nil,
                observedTreeDigest: nil,
                baselineRootIdentity: nil,
                observedRootIdentity: nil,
                baselineEntryIdentity: nil,
                observedEntryIdentity: nil
            ),
        ]
    } ?? []
    return ManagedSkillUpdateCheckSnapshot(
        skillID: skillID,
        checkedAtMilliseconds: 1,
        status: status,
        domainRevision: 1,
        domainPayloadDigest: Data(repeating: 4, count: 32),
        storedFingerprint: live,
        liveSSOTIdentity: nil,
        liveFingerprint: live,
        candidate: candidate,
        copyStates: copyStates,
        capabilityReason: capabilityReason
    )
}

func skillBatchPreview(
    _ snapshot: ManagedSkillUpdateCheckSnapshot
) throws -> ManagedSkillUpdateExecutionPreview {
    ManagedSkillUpdateExecutionPreview(
        token: ManagedSkillUpdateExecutionToken(),
        skillID: snapshot.skillID,
        displayName: "Demo",
        currentSourceDescription: "Current",
        candidateSourceDescription: "Candidate",
        distributionDescription: "Disabled",
        currentFingerprint: try #require(snapshot.liveFingerprint),
        candidate: try #require(snapshot.candidate),
        copyChoices: snapshot.copyStates.filter(\.isTargetDrift).map {
            ManagedSkillUpdateCopyChoice(
                scopeKey: $0.scopeKey,
                targetDescription: $0.scopeKey
            )
        }
    )
}
