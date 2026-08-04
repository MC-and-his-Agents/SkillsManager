import Foundation

nonisolated struct CustomRepositoryDiscoveryCandidate: Equatable, Sendable {
    let subpath: RepositorySubpath
    let displayName: String
    let providerAlias: ProviderAliasIdentity
}

nonisolated struct CustomRepositoryDiscovery: Equatable, Sendable {
    let repositoryID: UUID
    let databaseRevision: Int64
    let repositoryURL: NormalizedRepositoryURL
    let requestedRef: CustomRepositoryRef
    let commitSHA: String
    let treeSHA: String
    let candidates: [CustomRepositoryDiscoveryCandidate]
}

nonisolated enum CustomRepositoryDiscoveryError: Error, Equatable, Sendable {
    case notFound
    case disabled
    case staleCatalog
}

nonisolated struct CustomRepositoryInstallSnapshot: Equatable, Sendable {
    let repositoryID: UUID
    let databaseRevision: Int64
    let repositoryURL: NormalizedRepositoryURL
    let requestedRef: CustomRepositoryRef
    let commitSHA: String
    let subpath: RepositorySubpath

    func admit(_ record: CustomRepositoryCatalogRecord?) throws {
        guard let record else { throw CustomRepositoryDiscoveryError.staleCatalog }
        guard record.enabled,
              record.repositoryID == repositoryID,
              record.databaseRevision == databaseRevision,
              record.repositoryURL == repositoryURL,
              record.requestedRef == requestedRef else {
            throw CustomRepositoryDiscoveryError.staleCatalog
        }
    }

    func managedSourceInput(
        displayName: String,
        distributionSlug: DefaultDistributionSlug,
        loadCatalog: @escaping @Sendable (UUID) async throws -> CustomRepositoryCatalogRecord?,
        refresh: @escaping @Sendable (
            CustomRepositoryCatalogRecord
        ) async throws -> CustomRepositoryDiscovery
    ) throws -> ManagedSourceInstallInput {
        let repository = try SkillsShGitHubContract.existingInput(
            repositoryURL: repositoryURL,
            subpath: subpath
        )
        let archiveURL = try SkillsShGitHubContract.apiURL(path: [
            "repos", repository.owner, repository.repository, "zipball", commitSHA,
        ])
        return ManagedSourceInstallInput(
            displayName: displayName,
            distributionSlug: distributionSlug,
            repositoryURL: repositoryURL,
            subpath: subpath,
            revision: try SourceRevision(commitSHA),
            downloadURL: try PublicDownloadURL(archiveURL.absoluteString),
            alias: try .github(repositoryURL: repositoryURL, subpath: subpath),
            refreshHead: {
                let current = try await loadCatalog(repositoryID)
                try admit(current)
                guard let current else { throw CustomRepositoryDiscoveryError.staleCatalog }
                let discovery = try await refresh(current)
                guard discovery.candidates.contains(where: { $0.subpath == subpath }) else {
                    throw CustomRepositoryDiscoveryError.staleCatalog
                }
                return try SourceRevision(discovery.commitSHA)
            },
            finalAdmission: {
                try admit(try await loadCatalog(repositoryID))
            }
        )
    }
}

actor CustomRepositoryDiscoverySession {
    typealias CatalogLoader = @Sendable (UUID) async throws -> CustomRepositoryCatalogRecord?
    typealias Discoverer = @Sendable (
        CustomRepositoryCatalogRecord
    ) async throws -> CustomRepositoryDiscovery

    private let loadCatalog: CatalogLoader
    private let discover: Discoverer
    private var generation = 0

    init(loadCatalog: @escaping CatalogLoader, discover: @escaping Discoverer) {
        self.loadCatalog = loadCatalog
        self.discover = discover
    }

    func refresh(repositoryID: UUID) async throws -> CustomRepositoryDiscovery {
        generation += 1
        let requestedGeneration = generation
        guard let initial = try await loadCatalog(repositoryID) else {
            throw CustomRepositoryDiscoveryError.notFound
        }
        guard initial.enabled else { throw CustomRepositoryDiscoveryError.disabled }
        let result = try await discover(initial)
        guard requestedGeneration == generation,
              let current = try await loadCatalog(repositoryID),
              current == initial,
              result.repositoryID == initial.repositoryID,
              result.databaseRevision == initial.databaseRevision,
              result.repositoryURL == initial.repositoryURL,
              result.requestedRef == initial.requestedRef else {
            throw CustomRepositoryDiscoveryError.staleCatalog
        }
        return result
    }
}

actor CustomRepositoryDiscoveryResolver {
    private struct TaskKey: Hashable {
        let repositoryID: UUID
        let databaseRevision: Int64
    }

    let load: SkillsShGitHubSourceClient.DataLoader
    private var tasks: [TaskKey: Task<CustomRepositoryDiscovery, Error>] = [:]

    init(load: @escaping SkillsShGitHubSourceClient.DataLoader) {
        self.load = load
    }

    func resolve(_ catalog: CustomRepositoryCatalogRecord) async throws -> CustomRepositoryDiscovery {
        guard catalog.enabled else { throw SkillsShGitHubSourceError.repositoryUnavailable }
        guard !Task.isCancelled else { throw SkillsShGitHubSourceError.cancelled }
        let key = TaskKey(
            repositoryID: catalog.repositoryID,
            databaseRevision: catalog.databaseRevision
        )
        if let task = tasks[key] {
            do {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } catch {
                throw SkillsShGitHubContract.stable(error)
            }
        }
        let task = Task { try await SkillsShGitHubContract.discovery(catalog, load: load) }
        tasks[key] = task
        defer { tasks[key] = nil }
        do {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } catch {
            throw SkillsShGitHubContract.stable(error)
        }
    }
}

nonisolated extension SkillsShGitHubContract {
    static func discovery(
        _ catalog: CustomRepositoryCatalogRecord,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> CustomRepositoryDiscovery {
        do {
            let input = try existingInput(
                repositoryURL: catalog.repositoryURL,
                subpath: RepositorySubpath("")
            )
            let repository = try await repository(
                owner: input.owner,
                repository: input.repository,
                load: load
            )
            let ref = switch catalog.requestedRef {
            case .defaultBranch: repository.defaultBranch
            case .explicit(let value): value
            }
            let commit = try await commit(
                owner: input.owner,
                repository: input.repository,
                defaultBranch: ref,
                load: load
            )
            let entries = try await treeEntries(
                owner: input.owner,
                repository: input.repository,
                treeSHA: commit.commit.tree.sha,
                load: load
            )
            return CustomRepositoryDiscovery(
                repositoryID: catalog.repositoryID,
                databaseRevision: catalog.databaseRevision,
                repositoryURL: catalog.repositoryURL,
                requestedRef: catalog.requestedRef,
                commitSHA: commit.sha,
                treeSHA: commit.commit.tree.sha,
                candidates: try discoveryCandidates(
                    entries,
                    repositoryURL: catalog.repositoryURL,
                    repositoryName: input.repository
                )
            )
        } catch {
            throw stable(error)
        }
    }

    static func discoveryCandidates(
        _ entries: [TreeEntry],
        repositoryURL: NormalizedRepositoryURL,
        repositoryName: String
    ) throws -> [CustomRepositoryDiscoveryCandidate] {
        guard entries.allSatisfy({
            ($0.type == "tree" && $0.mode == "040000")
                || ($0.type == "blob" && ($0.mode == "100644" || $0.mode == "100755"))
        }) else {
            throw SkillsShGitHubSourceError.contractChanged
        }
        let manifests = entries.filter {
            $0.type == "blob"
                && ($0.mode == "100644" || $0.mode == "100755")
                && $0.components.last == "SKILL.md"
        }
        var subpaths: [RepositorySubpath] = []
        subpaths.reserveCapacity(manifests.count)
        for manifest in manifests {
            let raw = manifest.components.dropLast().joined(separator: "/")
            let subpath = try RepositorySubpath(raw)
            guard subpath.value == raw else { throw SkillsShGitHubSourceError.contractChanged }
            subpaths.append(subpath)
        }
        subpaths.sort { $0.value.utf8.lexicographicallyPrecedes($1.value.utf8) }
        for (index, parent) in subpaths.enumerated() {
            for child in subpaths.dropFirst(index + 1) where parent.value.isEmpty
                || child.value.hasPrefix(parent.value + "/") {
                _ = child
                throw SkillsShGitHubSourceError.contractChanged
            }
        }
        return try subpaths.map { subpath in
            CustomRepositoryDiscoveryCandidate(
                subpath: subpath,
                displayName: subpath.value.split(separator: "/").last.map(String.init)
                    ?? repositoryName,
                providerAlias: try .github(
                    repositoryURL: repositoryURL,
                    subpath: subpath
                )
            )
        }
    }
}
