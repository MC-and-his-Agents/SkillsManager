import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("SkillDiscoveryViewModel state")
struct SkillDiscoveryViewModelTests {
    @Test("partial results preserve observations and root diagnostics")
    @MainActor
    func partialResultPublishesSummary() async throws {
        let probe = SkillDiscoveryScanProbe()
        let root = discoveryTestRoot()
        let observation = discoveryTestObservation(status: .unmanaged)
        let viewModel = discoveryTestViewModel(scanProbe: probe, roots: [root])

        let refresh = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(1))
        #expect(viewModel.loadState == .loading)
        await probe.succeedNext(SkillDiscoveryResult(
            observations: [observation],
            rootDiagnostics: [SkillDiscoveryRootDiagnostic(
                root: root,
                reason: .rootPermissionDenied
            )]
        ))
        await refresh.value

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.items.map(\.observation.status) == [.unmanaged])
        #expect(viewModel.summary.discoveredCount == 1)
        #expect(viewModel.summary.unmanagedCount == 1)
        #expect(viewModel.summary.failedRootCount == 1)
        #expect(viewModel.rootDiagnostics.map(\.reason) == [.rootPermissionDenied])
    }

    @Test("empty result and terminal observation states remain distinguishable")
    @MainActor
    func emptyAndTerminalStates() async throws {
        let probe = SkillDiscoveryScanProbe()
        let viewModel = discoveryTestViewModel(scanProbe: probe)

        let emptyRefresh = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(1))
        await probe.succeedNext(discoveryTestResult())
        await emptyRefresh.value

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.items.isEmpty)
        #expect(viewModel.rootDiagnostics.isEmpty)

        let terminalRefresh = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(2))
        await probe.succeedNext(SkillDiscoveryResult(
            observations: [
                discoveryTestObservation(status: .conflict, reason: .evidenceConflict),
                discoveryTestObservation(
                    name: "locked",
                    status: .permissionDenied,
                    reason: .candidatePermissionDenied
                ),
                discoveryTestObservation(
                    name: "damaged",
                    status: .damaged,
                    reason: .missingSkillManifest
                ),
            ],
            rootDiagnostics: []
        ))
        await terminalRefresh.value

        #expect(viewModel.items.map(\.observation.status) == [
            .conflict,
            .permissionDenied,
            .damaged,
        ])
        #expect(viewModel.summary.conflictCount == 1)
    }

    @Test("collision-equivalent directory names keep distinct list identities")
    @MainActor
    func collisionItemsHaveUniqueIDs() async throws {
        let probe = SkillDiscoveryScanProbe()
        let viewModel = discoveryTestViewModel(scanProbe: probe)
        let upper = discoveryTestObservation(
            name: "Demo",
            status: .conflict,
            reason: .scopeSlugConflict
        )
        let lower = discoveryTestObservation(
            name: "demo",
            status: .conflict,
            reason: .scopeSlugConflict
        )
        #expect(upper.relativeLocatorKey == lower.relativeLocatorKey)

        let refresh = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(1))
        await probe.succeedNext(SkillDiscoveryResult(
            observations: [upper, lower],
            rootDiagnostics: []
        ))
        await refresh.value

        #expect(viewModel.items.count == 2)
        #expect(Set(viewModel.items.map(\.id)).count == 2)
        #expect(Set(viewModel.items.map(\.observation.rawRelativeLocator)) == ["Demo", "demo"])
    }

    @Test("a refresh published during preview invalidates the old preview")
    @MainActor
    func refreshSupersedesPreview() async throws {
        let scanProbe = SkillDiscoveryScanProbe()
        let previewProbe = SkillDiscoveryPreviewProbe()
        let observation = discoveryTestObservation(status: .unmanaged)
        let viewModel = discoveryTestViewModel(
            scanProbe: scanProbe,
            preview: { try await previewProbe.preview($0, action: $1) }
        )

        let initialRefresh = Task { await viewModel.refresh() }
        #expect(await scanProbe.waitForCallCount(1))
        await scanProbe.succeedNext(discoveryTestResult(observation))
        await initialRefresh.value
        let itemID = try #require(viewModel.items.first?.id)

        let preparation = Task {
            try await viewModel.prepareImport(itemID: itemID, action: .importNew)
        }
        #expect(await previewProbe.waitForCallCount(1))
        let newerRefresh = Task { await viewModel.refresh() }
        #expect(await scanProbe.waitForCallCount(2))
        await scanProbe.succeedNext(discoveryTestResult(observation))
        await newerRefresh.value
        await previewProbe.succeed()

        await #expect(throws: SkillDiscoveryFlowError.previewSuperseded) {
            try await preparation.value
        }
        #expect(viewModel.pendingImport == nil)
        #expect(viewModel.isPreparingPreview == false)
    }
}

actor SkillDiscoveryScanProbe {
    private var continuations: [
        UUID: CheckedContinuation<SkillDiscoveryResult, any Error>
    ] = [:]
    private var order: [UUID] = []
    private var cancelled: Set<UUID> = []
    private(set) var callCount = 0

    func scan(_ roots: [SkillDiscoveryRoot]) async throws -> SkillDiscoveryResult {
        _ = roots
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callCount += 1
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[id] = continuation
                    order.append(id)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitForCallCount(_ expected: Int) async -> Bool {
        for _ in 0..<10_000 {
            if callCount >= expected { return true }
            await Task.yield()
        }
        return false
    }

    func succeedNext(_ result: SkillDiscoveryResult) {
        guard let id = order.first else { return }
        order.removeFirst()
        continuations.removeValue(forKey: id)?.resume(returning: result)
    }

    func failNext(_ error: any Error) {
        guard let id = order.first else { return }
        order.removeFirst()
        continuations.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func cancel(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else {
            cancelled.insert(id)
            return
        }
        order.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}

actor SkillDiscoveryPreviewProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func preview(
        _ observation: SkillDiscoveryObservation,
        action: ManagedSkillImportAction
    ) async throws -> ManagedSkillImportPreview {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        return discoveryTestPreview(observation: observation, action: action)
    }

    func waitForCallCount(_ expected: Int) async -> Bool {
        for _ in 0..<10_000 {
            if callCount >= expected { return true }
            await Task.yield()
        }
        return false
    }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}

enum SkillDiscoveryTestError: Error, LocalizedError, Sendable {
    case retryable

    var errorDescription: String? { "Retryable discovery failure." }
}

@MainActor
func discoveryTestViewModel(
    scanProbe: SkillDiscoveryScanProbe,
    roots: [SkillDiscoveryRoot] = [discoveryTestRoot()],
    preview: @escaping @Sendable (
        SkillDiscoveryObservation,
        ManagedSkillImportAction
    ) async throws -> ManagedSkillImportPreview = {
        discoveryTestPreview(observation: $0, action: $1)
    },
    execute: @escaping @Sendable (
        ManagedSkillImportToken
    ) async throws -> ManagedSkillImportResult = { _ in
        try discoveryTestImportResult()
    }
) -> SkillDiscoveryViewModel {
    let viewModel = SkillDiscoveryViewModel()
    viewModel.activate(
        dependencies: SkillDiscoveryDependencies(
            scan: { try await scanProbe.scan($0) },
            preview: preview,
            execute: execute
        ),
        roots: { roots }
    )
    return viewModel
}

func discoveryTestRoot(
    scope: SkillDiscoveryScope = .global,
    name: String = "root"
) -> SkillDiscoveryRoot {
    SkillDiscoveryRoot(
        scope: scope,
        url: URL(fileURLWithPath: "/discovery/\(name)", isDirectory: true)
    )
}

func discoveryTestObservation(
    name: String = "demo",
    status: SkillDiscoveryStatus,
    reason: SkillDiscoveryReason? = nil,
    matchedSkillID: SkillID? = nil
) -> SkillDiscoveryObservation {
    SkillDiscoveryObservation(
        roots: [discoveryTestRoot()],
        rootIdentity: ManagedItemIdentity(stat()),
        rawRelativeLocator: name,
        relativeLocator: name,
        relativeLocatorKey: SkillContentPath.collisionKey(for: name),
        candidateIdentity: ManagedItemIdentity(stat()),
        fingerprint: try! SkillContentFingerprint(currentDigest: Data(repeating: 7, count: 32)),
        providerAliases: [],
        status: status,
        reason: reason,
        matchedSkillID: matchedSkillID,
        matchedSourceKey: nil
    )
}

func discoveryTestResult(
    _ observation: SkillDiscoveryObservation? = nil,
    diagnostics: [SkillDiscoveryRootDiagnostic] = []
) -> SkillDiscoveryResult {
    SkillDiscoveryResult(
        observations: observation.map { [$0] } ?? [],
        rootDiagnostics: diagnostics
    )
}

func discoveryTestPreview(
    observation: SkillDiscoveryObservation,
    action: ManagedSkillImportAction
) -> ManagedSkillImportPreview {
    ManagedSkillImportPreview(
        token: ManagedSkillImportToken(),
        action: action,
        displayName: observation.relativeLocator,
        matchedSkillID: observation.matchedSkillID,
        newSkillID: action == .importNew ? SkillID() : nil
    )
}

func discoveryTestImportResult(
    disposition: ManagedSkillImportDisposition = .created
) throws -> ManagedSkillImportResult {
    let fingerprint = try SkillContentFingerprint(currentDigest: Data(repeating: 9, count: 32))
    return ManagedSkillImportResult(
        skill: try ManagedSkillRecord(
            displayName: SkillDisplayName("Demo"),
            defaultDistributionSlug: DefaultDistributionSlug(validating: "demo"),
            contentFingerprint: fingerprint,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        ),
        disposition: disposition
    )
}
