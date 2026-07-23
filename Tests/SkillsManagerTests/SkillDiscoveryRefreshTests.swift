import Foundation
import Testing

@testable import SkillsManager

@Suite("SkillDiscoveryRefresh orchestration")
struct SkillDiscoveryRefreshTests {
    @Test("concurrent triggers collapse to one rerun and stale results never publish")
    @MainActor
    func coalescesTriggersAndRejectsStaleResults() async throws {
        let probe = SkillDiscoveryScanProbe()
        let viewModel = discoveryTestViewModel(scanProbe: probe)
        let stale = discoveryTestObservation(name: "stale", status: .unmanaged)
        let current = discoveryTestObservation(name: "current", status: .unmanaged)

        let first = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(1))
        let second = Task { await viewModel.refresh() }
        let third = Task { await viewModel.refresh() }
        await probe.succeedNext(discoveryTestResult(stale))

        #expect(await probe.waitForCallCount(2))
        #expect(viewModel.items.isEmpty)
        await probe.succeedNext(discoveryTestResult(current))
        await first.value
        await second.value
        await third.value

        #expect(await probe.callCount == 2)
        #expect(viewModel.items.map(\.observation.relativeLocator) == ["current"])
        #expect(viewModel.isRefreshing == false)
    }

    @Test("blocking runtime cancels refresh without publishing failure and retry succeeds")
    @MainActor
    func cancellationBlockedAndRetry() async throws {
        let probe = SkillDiscoveryScanProbe()
        let viewModel = discoveryTestViewModel(scanProbe: probe)

        let cancelledRefresh = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(1))
        viewModel.blockRuntime(message: "Library unavailable")
        await cancelledRefresh.value

        #expect(viewModel.loadState == .blocked("Library unavailable"))
        #expect(viewModel.isRefreshing == false)
        #expect(viewModel.items.isEmpty)

        viewModel.activate(
            dependencies: SkillDiscoveryDependencies(
                scan: { try await probe.scan($0) },
                preview: { discoveryTestPreview(observation: $0, action: $1) },
                execute: { _ in try discoveryTestImportResult() }
            ),
            roots: { [discoveryTestRoot()] }
        )
        let retry = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(2))
        await probe.succeedNext(discoveryTestResult(
            discoveryTestObservation(status: .unmanaged)
        ))
        await retry.value

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.items.count == 1)
    }

    @Test("scan failures are retryable and preflight fails closed for affected scopes")
    @MainActor
    func failureRetryAndPreflight() async throws {
        let probe = SkillDiscoveryScanProbe()
        let root = discoveryTestRoot()
        let diagnostic = SkillDiscoveryRootDiagnostic(
            root: root,
            reason: .rootPermissionDenied
        )
        let observation = discoveryTestObservation(status: .unmanaged)
        let partial = discoveryTestResult(observation, diagnostics: [diagnostic])
        let viewModel = discoveryTestViewModel(scanProbe: probe, roots: [root])

        let failedRefresh = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(1))
        await probe.failNext(SkillDiscoveryTestError.retryable)
        await failedRefresh.value
        #expect(viewModel.loadState == .failed("Retryable discovery failure."))

        let retry = Task { await viewModel.refresh() }
        #expect(await probe.waitForCallCount(2))
        await probe.succeedNext(partial)
        await retry.value
        #expect(viewModel.loadState == .loaded)

        let blockedPreflight = Task {
            try await viewModel.preflightRefresh(scopes: [.global])
        }
        #expect(await probe.waitForCallCount(3))
        await probe.succeedNext(partial)
        await #expect(throws: SkillDiscoveryPreflightError.rootUnavailable) {
            try await blockedPreflight.value
        }

        let agentScope = SkillDiscoveryScope.agent(
            adapterCode: "codex",
            pathVariant: ".codex/skills"
        )
        let allowedPreflight = Task {
            try await viewModel.preflightRefresh(scopes: [agentScope])
        }
        #expect(await probe.waitForCallCount(4))
        await probe.succeedNext(partial)
        let snapshot = try await allowedPreflight.value
        #expect(snapshot.result.observations.count == 1)
    }
}
