import Foundation
import Observation

nonisolated struct CustomRepositoryDependencies: Sendable {
    let list: @Sendable () async throws -> [CustomRepositoryCatalogRecord]
    let insert:
        @Sendable (CustomRepositoryCatalogInput) async throws -> CustomRepositoryCatalogRecord
    let remove: @Sendable (UUID, Int64) async throws -> Void
    let discover:
        @Sendable (CustomRepositoryCatalogRecord) async throws -> CustomRepositoryDiscovery

    static func live(
        writer: JournaledSSOTWriter,
        client: SkillsShGitHubSourceClient = .live()
    ) -> Self {
        let session = CustomRepositorySession(writer: writer, client: client)
        return Self(
            list: { try await session.list() },
            insert: { try await session.insert($0) },
            remove: { try await session.remove(id: $0, expectedRevision: $1) },
            discover: { try await session.discover($0) }
        )
    }
}

private actor CustomRepositorySession {
    let writer: JournaledSSOTWriter
    let client: SkillsShGitHubSourceClient

    init(writer: JournaledSSOTWriter, client: SkillsShGitHubSourceClient) {
        self.writer = writer
        self.client = client
    }

    func list() async throws -> [CustomRepositoryCatalogRecord] {
        try await writer.listCustomRepositories()
    }

    func insert(
        _ input: CustomRepositoryCatalogInput
    ) async throws -> CustomRepositoryCatalogRecord {
        try await writer.insertCustomRepository(input)
    }

    func remove(id: UUID, expectedRevision: Int64) async throws {
        try await writer.removeCustomRepository(id: id, expectedRevision: expectedRevision)
    }

    func discover(
        _ record: CustomRepositoryCatalogRecord
    ) async throws -> CustomRepositoryDiscovery {
        try await client.discoverRepository(record)
    }
}

nonisolated struct CustomRepositoryCandidateID: Hashable, Sendable {
    let repositoryID: UUID
    let subpath: RepositorySubpath
}

nonisolated struct CustomRepositoryCandidate: Identifiable, Equatable, Sendable {
    let id: CustomRepositoryCandidateID
    let repository: CustomRepositoryCatalogRecord
    let snapshot: CustomRepositoryInstallSnapshot
    let displayName: String
    let distributionSlug: DefaultDistributionSlug?

    var installProblem: String? {
        distributionSlug == nil ? "This Skill cannot form a valid distribution slug." : nil
    }

    var accessibilitySummary: String {
        "\(displayName), Available, Repository, \(repository.displayName), subpath "
            + (snapshot.subpath.value.isEmpty ? "root" : snapshot.subpath.value)
    }
}

@MainActor
@Observable final class CustomRepositoryViewModel {
    enum RepositoryState: Equatable, Sendable {
        case idle
        case loading
        case loaded(Int)
        case empty
        case failed(Problem)
    }

    enum Problem: Equatable, Sendable {
        case invalidURL
        case invalidRef
        case alreadyExists
        case notFound
        case conflict
        case rateLimited
        case offline
        case timeout
        case cancelled
        case unavailable
        case treeTooLarge
        case noUniqueSkill
        case contractChanged

        var message: String {
            switch self {
            case .invalidURL: "Enter a public https://github.com/owner/repository URL."
            case .invalidRef: "Enter a valid Git branch, tag, or commit reference."
            case .alreadyExists: "This GitHub repository is already registered."
            case .notFound: "The repository is no longer registered."
            case .conflict: "The repository changed. Review the latest catalog state and try again."
            case .rateLimited: "GitHub rate limited this request."
            case .offline: "GitHub is unavailable while the network is offline."
            case .timeout: "GitHub did not respond in time."
            case .cancelled: "The GitHub request was cancelled."
            case .unavailable: "The GitHub repository is unavailable."
            case .treeTooLarge: "The GitHub repository tree is too large to inspect safely."
            case .noUniqueSkill: "The selected repository path does not identify one Skill."
            case .contractChanged: "GitHub returned an unsupported repository layout."
            }
        }
    }

    private(set) var repositories: [CustomRepositoryCatalogRecord] = []
    private(set) var candidates: [CustomRepositoryCandidate] = []
    private(set) var states: [UUID: RepositoryState] = [:]
    private(set) var operationProblem: Problem?
    private(set) var isMutating = false

    private var dependencies: CustomRepositoryDependencies?
    private var runtimeReady = false
    private var generations: [UUID: UInt64] = [:]
    private var refreshingCandidates: [CustomRepositoryCandidateID: CustomRepositoryCandidate] = [:]

    var isRefreshing: Bool {
        states.values.contains(.loading)
    }

    @discardableResult
    func activate(dependencies: CustomRepositoryDependencies) -> Bool {
        let needsInitialLoad = !runtimeReady
        self.dependencies = dependencies
        runtimeReady = true
        operationProblem = nil
        return needsInitialLoad
    }

    func blockRuntime(message: String) {
        _ = message
        runtimeReady = false
        generations = generations.mapValues { $0 &+ 1 }
        repositories = []
        candidates = []
        refreshingCandidates = [:]
        states = [:]
        operationProblem = .unavailable
        isMutating = false
    }

    func loadAndRefresh() async {
        guard await reloadCatalog() else { return }
        await refreshAll()
    }

    func reloadCatalog() async -> Bool {
        guard runtimeReady, let dependencies else { return false }
        do {
            let loaded = try await dependencies.list()
            guard runtimeReady else { return false }
            let previousRevisions = Dictionary(uniqueKeysWithValues: repositories.map {
                ($0.repositoryID, $0.databaseRevision)
            })
            repositories = loaded
            let revisions = Dictionary(uniqueKeysWithValues: loaded.map {
                ($0.repositoryID, $0.databaseRevision)
            })
            for record in loaded
            where previousRevisions[record.repositoryID] != record.databaseRevision {
                generations[record.repositoryID, default: 0] &+= 1
                states[record.repositoryID] = .idle
            }
            candidates.removeAll {
                revisions[$0.repository.repositoryID] != $0.repository.databaseRevision
            }
            refreshingCandidates = refreshingCandidates.filter {
                revisions[$0.value.repository.repositoryID]
                    == $0.value.repository.databaseRevision
            }
            states = states.filter { revisions[$0.key] != nil }
            operationProblem = nil
            return true
        } catch {
            operationProblem = Self.problem(error)
            return false
        }
    }

    func add(repositoryURL: String, requestedRef: String) async {
        guard runtimeReady, let dependencies, !isMutating else { return }
        isMutating = true
        operationProblem = nil
        defer { isMutating = false }
        do {
            let trimmedRef = requestedRef.trimmingCharacters(in: .whitespacesAndNewlines)
            let input = try CustomRepositoryCatalogInput(
                repositoryURL: repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines),
                requestedRef: trimmedRef.isEmpty
                    ? .defaultBranch
                    : try .explicit(validating: trimmedRef)
            )
            let inserted = try await dependencies.insert(input)
            guard runtimeReady else { return }
            _ = await reloadCatalog()
            await refresh(repositoryID: inserted.repositoryID)
        } catch {
            operationProblem = Self.problem(error)
        }
    }

    func remove(_ record: CustomRepositoryCatalogRecord) async -> Bool {
        guard runtimeReady, let dependencies, !isMutating else { return false }
        isMutating = true
        operationProblem = nil
        defer { isMutating = false }
        do {
            try await dependencies.remove(record.repositoryID, record.databaseRevision)
            guard runtimeReady else { return false }
            repositories.removeAll { $0.repositoryID == record.repositoryID }
            candidates.removeAll { $0.repository.repositoryID == record.repositoryID }
            refreshingCandidates = refreshingCandidates.filter {
                $0.value.repository.repositoryID != record.repositoryID
            }
            states[record.repositoryID] = nil
            generations[record.repositoryID, default: 0] &+= 1
            return true
        } catch {
            _ = await reloadCatalog()
            operationProblem = Self.problem(error)
            return false
        }
    }

    func refreshAll() async {
        for record in repositories where record.enabled {
            guard runtimeReady else { return }
            await refresh(repositoryID: record.repositoryID)
        }
    }

    func refresh(repositoryID: UUID) async {
        guard runtimeReady, let dependencies,
              let record = repositories.first(where: { $0.repositoryID == repositoryID }) else {
            return
        }
        generations[repositoryID, default: 0] &+= 1
        let generation = generations[repositoryID, default: 0]
        for candidate in candidates where candidate.repository.repositoryID == repositoryID {
            refreshingCandidates[candidate.id] = candidate
        }
        candidates.removeAll { $0.repository.repositoryID == repositoryID }
        states[repositoryID] = .loading
        do {
            let discovery = try await dependencies.discover(record)
            guard isCurrent(record, generation: generation),
                  discovery.repositoryID == record.repositoryID,
                  discovery.databaseRevision == record.databaseRevision else { return }
            let values = discovery.candidates.map {
                candidate($0, discovery: discovery, repository: record)
            }
            candidates.append(contentsOf: values)
            candidates.sort(by: Self.candidateOrder)
            states[repositoryID] = values.isEmpty ? .empty : .loaded(values.count)
            refreshingCandidates = refreshingCandidates.filter {
                $0.value.repository.repositoryID != repositoryID
            }
        } catch {
            guard isCurrent(record, generation: generation) else { return }
            candidates.removeAll { $0.repository.repositoryID == repositoryID }
            states[repositoryID] = .failed(Self.problem(error))
            refreshingCandidates = refreshingCandidates.filter {
                $0.value.repository.repositoryID != repositoryID
            }
        }
    }

    func state(for repositoryID: UUID) -> RepositoryState {
        states[repositoryID] ?? .idle
    }

    func candidate(id: CustomRepositoryCandidateID?) -> CustomRepositoryCandidate? {
        guard let id else { return nil }
        return candidates.first { $0.id == id } ?? refreshingCandidates[id]
    }

    private func isCurrent(
        _ record: CustomRepositoryCatalogRecord,
        generation: UInt64
    ) -> Bool {
        runtimeReady
            && generations[record.repositoryID] == generation
            && repositories.contains(record)
    }

    private func candidate(
        _ candidate: CustomRepositoryDiscoveryCandidate,
        discovery: CustomRepositoryDiscovery,
        repository: CustomRepositoryCatalogRecord
    ) -> CustomRepositoryCandidate {
        let slugName = candidate.subpath.value.split(separator: "/").last.map(String.init)
            ?? repository.repositoryURL.value.split(separator: "/").last.map(String.init)
            ?? candidate.displayName
        return CustomRepositoryCandidate(
            id: CustomRepositoryCandidateID(
                repositoryID: repository.repositoryID,
                subpath: candidate.subpath
            ),
            repository: repository,
            snapshot: CustomRepositoryInstallSnapshot(
                repositoryID: repository.repositoryID,
                databaseRevision: repository.databaseRevision,
                repositoryURL: repository.repositoryURL,
                requestedRef: repository.requestedRef,
                commitSHA: discovery.commitSHA,
                subpath: candidate.subpath
            ),
            displayName: candidate.displayName,
            distributionSlug: try? DefaultDistributionSlug(
                candidateFrom: SkillDisplayName(slugName)
            )
        )
    }

    private static func candidateOrder(
        _ lhs: CustomRepositoryCandidate,
        _ rhs: CustomRepositoryCandidate
    ) -> Bool {
        let left = "\(lhs.repository.repositoryURL.value)/\(lhs.snapshot.subpath.value)"
        let right = "\(rhs.repository.repositoryURL.value)/\(rhs.snapshot.subpath.value)"
        return left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private static func problem(_ error: Error) -> Problem {
        switch error {
        case CustomRepositoryCatalogError.invalidURL: .invalidURL
        case CustomRepositoryCatalogError.invalidRef: .invalidRef
        case CustomRepositoryCatalogError.alreadyExists: .alreadyExists
        case CustomRepositoryCatalogError.notFound,
             CustomRepositoryDiscoveryError.notFound: .notFound
        case CustomRepositoryCatalogError.conflict,
             CustomRepositoryDiscoveryError.staleCatalog: .conflict
        case SkillsShGitHubSourceError.rateLimited: .rateLimited
        case SkillsShGitHubSourceError.offline: .offline
        case SkillsShGitHubSourceError.timeout: .timeout
        case SkillsShGitHubSourceError.cancelled: .cancelled
        case SkillsShGitHubSourceError.treeTruncated: .treeTooLarge
        case SkillsShGitHubSourceError.noUniqueSkillMatch: .noUniqueSkill
        case SkillsShGitHubSourceError.contractChanged: .contractChanged
        default: .unavailable
        }
    }
}
