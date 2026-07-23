import Foundation
import Testing

@testable import SkillsManager

@Suite("SkillImportFlow")
struct SkillImportFlowTests {
    @Test("confirmed import publishes success only after execution and refreshes discovery")
    @MainActor
    func confirmedImportRefreshesAfterTerminalSuccess() async throws {
        let scanProbe = SkillDiscoveryScanProbe()
        let importProbe = SkillDiscoveryImportProbe(outcomes: [.success(.created)])
        let unmanaged = discoveryTestObservation(status: .unmanaged)
        let managed = discoveryTestObservation(status: .managed)
        let viewModel = discoveryTestViewModel(
            scanProbe: scanProbe,
            preview: { try await importProbe.preview($0, action: $1) },
            execute: { try await importProbe.execute($0) }
        )

        let initialRefresh = Task { await viewModel.refresh() }
        #expect(await scanProbe.waitForCallCount(1))
        await scanProbe.succeedNext(discoveryTestResult(unmanaged))
        await initialRefresh.value
        let itemID = try #require(viewModel.items.first?.id)
        try await viewModel.prepareImport(itemID: itemID, action: .importNew)

        let confirmation = Task { await viewModel.confirmPendingImport() }
        #expect(await importProbe.waitForExecuteCount(1))
        #expect(viewModel.importResultMessage == nil)
        #expect(await scanProbe.waitForCallCount(2))
        await scanProbe.succeedNext(discoveryTestResult(managed))
        await confirmation.value

        #expect(viewModel.pendingImport == nil)
        #expect(viewModel.importErrorMessage == nil)
        #expect(viewModel.importResultMessage?.contains("imported") == true)
        #expect(viewModel.items.map(\.observation.status) == [.managed])
        #expect(await importProbe.executeCount == 1)
    }

    @Test("claim preview targets the uniquely matched managed Skill")
    @MainActor
    func confirmedClaimUsesMatchedSkill() async throws {
        let scanProbe = SkillDiscoveryScanProbe()
        let importProbe = SkillDiscoveryImportProbe(outcomes: [.success(.claimed)])
        let matchedSkillID = SkillID()
        let claimable = discoveryTestObservation(
            status: .claimable,
            matchedSkillID: matchedSkillID
        )
        let viewModel = discoveryTestViewModel(
            scanProbe: scanProbe,
            preview: { try await importProbe.preview($0, action: $1) },
            execute: { try await importProbe.execute($0) }
        )

        let initialRefresh = Task { await viewModel.refresh() }
        #expect(await scanProbe.waitForCallCount(1))
        await scanProbe.succeedNext(discoveryTestResult(claimable))
        await initialRefresh.value
        let itemID = try #require(viewModel.items.first?.id)
        try await viewModel.prepareImport(itemID: itemID, action: .claimExisting)

        #expect(viewModel.pendingImport?.preview.action == .claimExisting)
        #expect(viewModel.pendingImport?.preview.matchedSkillID == matchedSkillID)
        #expect(viewModel.pendingImport?.preview.newSkillID == nil)

        let confirmation = Task { await viewModel.confirmPendingImport() }
        #expect(await importProbe.waitForExecuteCount(1))
        #expect(await scanProbe.waitForCallCount(2))
        await scanProbe.succeedNext(discoveryTestResult(
            discoveryTestObservation(status: .managed)
        ))
        await confirmation.value

        #expect(viewModel.pendingImport == nil)
        #expect(viewModel.importResultMessage?.contains("linked") == true)
    }

    @Test("recoverable execution failure keeps the preview and retries the same token")
    @MainActor
    func recoverableFailureRetriesPendingToken() async throws {
        let scanProbe = SkillDiscoveryScanProbe()
        let importProbe = SkillDiscoveryImportProbe(
            outcomes: [.recoverable, .success(.alreadyManaged)]
        )
        let observation = discoveryTestObservation(status: .unmanaged)
        let viewModel = discoveryTestViewModel(
            scanProbe: scanProbe,
            preview: { try await importProbe.preview($0, action: $1) },
            execute: { try await importProbe.execute($0) }
        )

        let refresh = Task { await viewModel.refresh() }
        #expect(await scanProbe.waitForCallCount(1))
        await scanProbe.succeedNext(discoveryTestResult(observation))
        await refresh.value
        let itemID = try #require(viewModel.items.first?.id)
        try await viewModel.prepareImport(itemID: itemID, action: .importNew)
        let token = try #require(viewModel.pendingImport?.preview.token)

        await viewModel.confirmPendingImport()
        #expect(viewModel.pendingImport?.preview.token == token)
        #expect(viewModel.importErrorMessage == "Retryable import failure.")
        #expect(viewModel.importResultMessage == nil)

        let retry = Task { await viewModel.confirmPendingImport() }
        #expect(await importProbe.waitForExecuteCount(2))
        #expect(await scanProbe.waitForCallCount(2))
        await scanProbe.succeedNext(discoveryTestResult(
            discoveryTestObservation(status: .managed)
        ))
        await retry.value

        #expect(await importProbe.tokens == [token, token])
        #expect(viewModel.pendingImport == nil)
        #expect(viewModel.importResultMessage?.contains("already managed") == true)
    }

    @Test("invalidated execution clears preview, reports the reason, and refreshes")
    @MainActor
    func invalidatedExecutionRequiresFreshPreview() async throws {
        let scanProbe = SkillDiscoveryScanProbe()
        let importProbe = SkillDiscoveryImportProbe(outcomes: [.sourceChanged])
        let observation = discoveryTestObservation(status: .unmanaged)
        let viewModel = discoveryTestViewModel(
            scanProbe: scanProbe,
            preview: { try await importProbe.preview($0, action: $1) },
            execute: { try await importProbe.execute($0) }
        )

        let initialRefresh = Task { await viewModel.refresh() }
        #expect(await scanProbe.waitForCallCount(1))
        await scanProbe.succeedNext(discoveryTestResult(observation))
        await initialRefresh.value
        let itemID = try #require(viewModel.items.first?.id)
        try await viewModel.prepareImport(itemID: itemID, action: .importNew)

        let confirmation = Task { await viewModel.confirmPendingImport() }
        #expect(await importProbe.waitForExecuteCount(1))
        #expect(await scanProbe.waitForCallCount(2))
        await scanProbe.succeedNext(discoveryTestResult(observation))
        await confirmation.value

        #expect(viewModel.pendingImport == nil)
        #expect(viewModel.importResultMessage == nil)
        #expect(viewModel.importErrorMessage?.contains("changed after preview") == true)
    }

    @Test("only approved conflict reasons expose independent import")
    func independentImportBoundary() {
        for reason in [
            SkillDiscoveryReason.ambiguousSource,
            .ambiguousFingerprint,
            .evidenceConflict,
        ] {
            let observation = discoveryTestObservation(
                status: .conflict,
                reason: reason
            )
            #expect(ManagedSkillImportService.allowedActions(for: observation) == [.importNew])
        }

        for reason in [
            SkillDiscoveryReason.unknownSymlink,
            .scopeSlugConflict,
            .ambiguousLocalAssociation,
            .localAssociationDrift,
        ] {
            let observation = discoveryTestObservation(
                status: .conflict,
                reason: reason
            )
            #expect(ManagedSkillImportService.allowedActions(for: observation).isEmpty)
        }
    }
}

actor SkillDiscoveryImportProbe {
    enum Outcome: Sendable {
        case success(ManagedSkillImportDisposition)
        case sourceChanged
        case recoverable
    }

    private var outcomes: [Outcome]
    private(set) var executeCount = 0
    private(set) var tokens: [ManagedSkillImportToken] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func preview(
        _ observation: SkillDiscoveryObservation,
        action: ManagedSkillImportAction
    ) throws -> ManagedSkillImportPreview {
        discoveryTestPreview(observation: observation, action: action)
    }

    func execute(_ token: ManagedSkillImportToken) throws -> ManagedSkillImportResult {
        executeCount += 1
        tokens.append(token)
        guard !outcomes.isEmpty else { throw SkillImportFlowTestError.retryable }
        switch outcomes.removeFirst() {
        case .success(let disposition):
            return try discoveryTestImportResult(disposition: disposition)
        case .sourceChanged:
            throw ManagedSkillImportError.sourceChanged
        case .recoverable:
            throw SkillImportFlowTestError.retryable
        }
    }

    func waitForExecuteCount(_ expected: Int) async -> Bool {
        for _ in 0..<10_000 {
            if executeCount >= expected { return true }
            await Task.yield()
        }
        return false
    }
}

private enum SkillImportFlowTestError: Error, LocalizedError {
    case retryable

    var errorDescription: String? { "Retryable import failure." }
}
