import Foundation
import Testing

@testable import SkillsManager

@Suite("Custom repository journey")
struct CustomRepositoryJourneyTests {
    @Test("adds, refreshes, and projects a repository candidate")
    @MainActor
    func addAndRefresh() async throws {
        let probe = RepositoryJourneyProbe()
        let model = CustomRepositoryViewModel()
        model.activate(dependencies: await probe.dependencies())

        await model.add(
            repositoryURL: "https://github.com/Owner/Repo.git",
            requestedRef: "release/v1"
        )

        let record = try #require(model.repositories.first)
        let candidate = try #require(model.candidates.first)
        let expectedRef = try CustomRepositoryRef.explicit(validating: "release/v1")
        #expect(record.repositoryURL.value == "https://github.com/owner/repo")
        #expect(record.requestedRef == expectedRef)
        #expect(model.state(for: record.repositoryID) == .loaded(1))
        #expect(candidate.id.repositoryID == record.repositoryID)
        #expect(candidate.id.subpath.value == "skills/demo")
        #expect(candidate.distributionSlug?.value == "demo")
        #expect(candidate.accessibilitySummary.contains("Available, Repository"))
    }

    @Test("rejects invalid input before catalog or network calls")
    @MainActor
    func invalidInput() async {
        let probe = RepositoryJourneyProbe()
        let model = CustomRepositoryViewModel()
        model.activate(dependencies: await probe.dependencies())

        await model.add(repositoryURL: "https://example.com/owner/repo", requestedRef: "")

        #expect(model.operationProblem == .invalidURL)
        #expect(await probe.insertCount == 0)
        #expect(await probe.discoveryCount == 0)
    }

    @Test("one failed repository does not remove another repository candidates")
    @MainActor
    func independentFailure() async throws {
        let good = try repository(id: UUID(), url: "https://github.com/owner/good")
        let bad = try repository(id: UUID(), url: "https://github.com/owner/bad")
        let probe = RepositoryJourneyProbe(records: [good, bad])
        await probe.failDiscovery(for: bad.repositoryID, with: .offline)
        let model = CustomRepositoryViewModel()
        model.activate(dependencies: await probe.dependencies())

        await model.loadAndRefresh()

        #expect(model.candidates.map(\.repository.repositoryID) == [good.repositoryID])
        #expect(model.state(for: good.repositoryID) == .loaded(1))
        #expect(model.state(for: bad.repositoryID) == .failed(.offline))
    }

    @Test("CAS conflict reloads current catalog and rejects stale candidates")
    @MainActor
    func removalConflict() async throws {
        let original = try repository(id: UUID(), revision: 0)
        let changed = try repository(id: original.repositoryID, revision: 1)
        let probe = RepositoryJourneyProbe(records: [original])
        let model = CustomRepositoryViewModel()
        model.activate(dependencies: await probe.dependencies())
        await model.loadAndRefresh()
        await probe.replaceRecords([changed])
        await probe.failRemoval(with: .conflict)

        #expect(await model.remove(original) == false)
        #expect(model.repositories == [changed])
        #expect(model.candidates.isEmpty)
        #expect(model.operationProblem == .conflict)
    }

    @Test("catalog revision change invalidates an in-flight refresh")
    @MainActor
    func staleRefresh() async throws {
        let initial = try repository(id: UUID(), revision: 0)
        let changed = try repository(id: initial.repositoryID, revision: 1)
        let catalog = RepositoryCatalogProbe([initial])
        let gate = RepositoryRefreshGate()
        let model = CustomRepositoryViewModel()
        model.activate(dependencies: CustomRepositoryDependencies(
            list: { await catalog.values },
            insert: { _ in throw CustomRepositoryCatalogError.conflict },
            remove: { _, _ in throw CustomRepositoryCatalogError.conflict },
            discover: { try await gate.discover($0) }
        ))
        #expect(await model.reloadCatalog())

        let refresh = Task { @MainActor in
            await model.refresh(repositoryID: initial.repositoryID)
        }
        await gate.waitUntilStarted()
        await catalog.replace([changed])
        #expect(await model.reloadCatalog())
        await gate.resume()
        await refresh.value

        #expect(model.repositories == [changed])
        #expect(model.candidates.isEmpty)
        #expect(model.state(for: changed.repositoryID) == .idle)
    }

    @Test("repository candidates obey available, source, agent, and selection filters")
    @MainActor
    func filtersAndSelection() async throws {
        var filters = SkillListFilters()
        #expect(filters.includesRemote(.repository))
        filters.status = .managed
        #expect(!filters.includesRemote(.repository))
        filters.status = .available
        filters.source = .source(.repository)
        #expect(filters.includesRemote(.repository))
        #expect(!filters.includesRemote(.skillsSh))
        filters.agent = .agent(.codex)
        #expect(!filters.includesRemote(.repository))

        let id = CustomRepositoryCandidateID(
            repositoryID: UUID(),
            subpath: try RepositorySubpath("skills/demo")
        )
        let selection = UnifiedSkillSelection.repository(id)
        #expect(reconciledSkillSelection(selection, visibleSelections: [selection]) == selection)
        #expect(reconciledSkillSelection(selection, visibleSelections: []) == nil)
    }

    private func repository(
        id: UUID,
        url: String = "https://github.com/owner/repo",
        revision: Int64 = 0
    ) throws -> CustomRepositoryCatalogRecord {
        CustomRepositoryCatalogRecord(
            repositoryID: id,
            repositoryURL: try NormalizedRepositoryURL(url),
            requestedRef: .defaultBranch,
            displayName: url.split(separator: "/").suffix(2).joined(separator: "/"),
            enabled: true,
            createdAtMilliseconds: 0,
            updatedAtMilliseconds: revision,
            databaseRevision: revision
        )
    }
}

private actor RepositoryJourneyProbe {
    private var records: [CustomRepositoryCatalogRecord]
    private var discoveryFailures: [UUID: SkillsShGitHubSourceError] = [:]
    private var removalFailure: CustomRepositoryCatalogError?
    private(set) var insertCount = 0
    private(set) var discoveryCount = 0

    init(records: [CustomRepositoryCatalogRecord] = []) {
        self.records = records
    }

    func dependencies() -> CustomRepositoryDependencies {
        CustomRepositoryDependencies(
            list: { await self.records },
            insert: { try await self.insert($0) },
            remove: { try await self.remove(id: $0, revision: $1) },
            discover: { try await self.discover($0) }
        )
    }

    func replaceRecords(_ records: [CustomRepositoryCatalogRecord]) {
        self.records = records
    }

    func failDiscovery(for id: UUID, with error: SkillsShGitHubSourceError) {
        discoveryFailures[id] = error
    }

    func failRemoval(with error: CustomRepositoryCatalogError) {
        removalFailure = error
    }

    private func insert(
        _ input: CustomRepositoryCatalogInput
    ) throws -> CustomRepositoryCatalogRecord {
        insertCount += 1
        guard !records.contains(where: { $0.repositoryURL == input.repositoryURL }) else {
            throw CustomRepositoryCatalogError.alreadyExists
        }
        let record = CustomRepositoryCatalogRecord(
            repositoryID: UUID(),
            repositoryURL: input.repositoryURL,
            requestedRef: input.requestedRef,
            displayName: input.displayName,
            enabled: input.enabled,
            createdAtMilliseconds: 0,
            updatedAtMilliseconds: 0,
            databaseRevision: 0
        )
        records.append(record)
        records.sort { $0.repositoryURL.value < $1.repositoryURL.value }
        return record
    }

    private func remove(id: UUID, revision: Int64) throws {
        if let removalFailure { throw removalFailure }
        guard let index = records.firstIndex(where: { $0.repositoryID == id }) else {
            throw CustomRepositoryCatalogError.notFound
        }
        guard records[index].databaseRevision == revision else {
            throw CustomRepositoryCatalogError.conflict
        }
        records.remove(at: index)
    }

    private func discover(
        _ record: CustomRepositoryCatalogRecord
    ) throws -> CustomRepositoryDiscovery {
        discoveryCount += 1
        if let failure = discoveryFailures[record.repositoryID] { throw failure }
        let subpath = try RepositorySubpath("skills/demo")
        return CustomRepositoryDiscovery(
            repositoryID: record.repositoryID,
            databaseRevision: record.databaseRevision,
            repositoryURL: record.repositoryURL,
            requestedRef: record.requestedRef,
            commitSHA: String(repeating: "a", count: 40),
            treeSHA: String(repeating: "b", count: 40),
            candidates: [CustomRepositoryDiscoveryCandidate(
                subpath: subpath,
                displayName: "Demo",
                providerAlias: try .github(repositoryURL: record.repositoryURL, subpath: subpath)
            )]
        )
    }
}

private actor RepositoryCatalogProbe {
    private(set) var values: [CustomRepositoryCatalogRecord]

    init(_ values: [CustomRepositoryCatalogRecord]) {
        self.values = values
    }

    func replace(_ values: [CustomRepositoryCatalogRecord]) {
        self.values = values
    }
}

private actor RepositoryRefreshGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func discover(
        _ record: CustomRepositoryCatalogRecord
    ) async throws -> CustomRepositoryDiscovery {
        started = true
        await withCheckedContinuation { continuation = $0 }
        let subpath = try RepositorySubpath("skills/demo")
        return CustomRepositoryDiscovery(
            repositoryID: record.repositoryID,
            databaseRevision: record.databaseRevision,
            repositoryURL: record.repositoryURL,
            requestedRef: record.requestedRef,
            commitSHA: String(repeating: "a", count: 40),
            treeSHA: String(repeating: "b", count: 40),
            candidates: [CustomRepositoryDiscoveryCandidate(
                subpath: subpath,
                displayName: "Demo",
                providerAlias: try .github(repositoryURL: record.repositoryURL, subpath: subpath)
            )]
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
