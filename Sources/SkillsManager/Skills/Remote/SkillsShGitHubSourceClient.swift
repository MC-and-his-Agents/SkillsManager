import Foundation

nonisolated struct SkillsShGitHubBlob: Equatable, Sendable {
    let relativePath: String
    let mode: String
    let size: Int
    let gitBlobSHA: String
}

nonisolated struct SkillsShResolvedGitHubSource: Equatable, Sendable {
    let repositoryURL: NormalizedRepositoryURL
    let owner: String
    let repository: String
    let defaultBranch: String
    let commitSHA: String
    let treeSHA: String
    let subpath: RepositorySubpath
    let blobs: [SkillsShGitHubBlob]
    let archiveURL: URL
    let providerAliasIdentifier: String
    let defaultDistributionSlug: DefaultDistributionSlug
}

nonisolated struct SkillsShResolvedGitHubUpdateSource: Equatable, Sendable {
    let repositoryURL: NormalizedRepositoryURL
    let owner: String
    let repository: String
    let defaultBranch: String
    let commitSHA: String
    let treeSHA: String
    let subpath: RepositorySubpath
    let blobs: [SkillsShGitHubBlob]
    let archiveURL: URL
}

nonisolated struct SkillsShGitHubArchive: Equatable, Sendable {
    let data: Data
    let sourceURL: URL
}

nonisolated enum SkillsShGitHubSourceError: Error, Equatable, LocalizedError, Sendable {
    case invalidSource
    case repositoryUnavailable
    case rateLimited
    case timeout
    case offline
    case network
    case cancelled
    case responseTooLarge
    case contractChanged
    case treeTruncated
    case noUniqueSkillMatch

    var errorDescription: String? {
        switch self {
        case .invalidSource: "The skills.sh GitHub source is invalid."
        case .repositoryUnavailable: "The GitHub repository is unavailable."
        case .rateLimited: "GitHub rate limited this request."
        case .timeout: "GitHub did not respond in time."
        case .offline: "GitHub is unavailable while the network is offline."
        case .network: "GitHub could not be reached."
        case .cancelled: "The GitHub source request was cancelled."
        case .responseTooLarge: "GitHub returned more data than can be handled safely."
        case .contractChanged: "The GitHub source response did not match the expected contract."
        case .treeTruncated: "The GitHub repository tree is too large to resolve safely."
        case .noUniqueSkillMatch: "The skills.sh result does not identify exactly one Skill."
        }
    }
}

nonisolated struct SkillsShGitHubSourceClient: Sendable {
    typealias DataLoader = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    var resolve: @Sendable (
        _ id: String,
        _ source: String,
        _ skillID: String
    ) async throws -> SkillsShResolvedGitHubSource
    var download: @Sendable (
        _ source: SkillsShResolvedGitHubSource
    ) async throws -> SkillsShGitHubArchive
    var resolveExisting: @Sendable (
        _ repositoryURL: NormalizedRepositoryURL,
        _ subpath: RepositorySubpath
    ) async throws -> SkillsShResolvedGitHubUpdateSource
    var downloadExisting: @Sendable (
        _ source: SkillsShResolvedGitHubUpdateSource
    ) async throws -> SkillsShGitHubArchive
    var currentCommitSHA: @Sendable (
        _ source: SkillsShResolvedGitHubSource
    ) async throws -> String

    static func live(
        load: @escaping DataLoader = SkillsShGitHubHTTPTransport.load
    ) -> SkillsShGitHubSourceClient {
        SkillsShGitHubSourceClient(
            resolve: { id, source, skillID in
                do {
                    let input = try SkillsShGitHubContract.input(
                        id: id,
                        source: source,
                        skillID: skillID
                    )
                    let repository = try await SkillsShGitHubContract.repository(input, load: load)
                    let commit = try await SkillsShGitHubContract.commit(
                        input,
                        defaultBranch: repository.defaultBranch,
                        load: load
                    )
                    return try await SkillsShGitHubContract.source(
                        input,
                        canonicalFullName: repository.fullName,
                        defaultBranch: repository.defaultBranch,
                        commit: commit,
                        load: load
                    )
                } catch {
                    throw SkillsShGitHubContract.stable(error)
                }
            },
            download: { source in
                do {
                    return try await SkillsShGitHubContract.archive(
                        owner: source.owner,
                        repository: source.repository,
                        commitSHA: source.commitSHA,
                        archiveURL: source.archiveURL,
                        load: load
                    )
                } catch {
                    throw SkillsShGitHubContract.stable(error)
                }
            },
            resolveExisting: { repositoryURL, subpath in
                do {
                    let input = try SkillsShGitHubContract.existingInput(
                        repositoryURL: repositoryURL,
                        subpath: subpath
                    )
                    let repository = try await SkillsShGitHubContract.repository(
                        owner: input.owner,
                        repository: input.repository,
                        load: load
                    )
                    let commit = try await SkillsShGitHubContract.commit(
                        owner: input.owner,
                        repository: input.repository,
                        defaultBranch: repository.defaultBranch,
                        load: load
                    )
                    return try await SkillsShGitHubContract.updateSource(
                        input,
                        canonicalFullName: repository.fullName,
                        defaultBranch: repository.defaultBranch,
                        commit: commit,
                        load: load
                    )
                } catch {
                    throw SkillsShGitHubContract.stable(error)
                }
            },
            downloadExisting: { source in
                do {
                    return try await SkillsShGitHubContract.archive(
                        owner: source.owner,
                        repository: source.repository,
                        commitSHA: source.commitSHA,
                        archiveURL: source.archiveURL,
                        load: load
                    )
                } catch {
                    throw SkillsShGitHubContract.stable(error)
                }
            },
            currentCommitSHA: { source in
                do {
                    let input = try SkillsShGitHubContract.input(
                        id: "\(source.owner)/\(source.repository)/\(source.defaultDistributionSlug.value)",
                        source: "\(source.owner)/\(source.repository)",
                        skillID: source.defaultDistributionSlug.value
                    )
                    let repository = try await SkillsShGitHubContract.repository(input, load: load)
                    guard repository.fullName.caseInsensitiveCompare(
                        "\(source.owner)/\(source.repository)"
                    ) == .orderedSame,
                          repository.defaultBranch == source.defaultBranch else {
                        throw SkillsShGitHubSourceError.repositoryUnavailable
                    }
                    return try await SkillsShGitHubContract.commit(
                        input,
                        defaultBranch: repository.defaultBranch,
                        load: load
                    ).sha
                } catch {
                    throw SkillsShGitHubContract.stable(error)
                }
            }
        )
    }
}

nonisolated enum SkillsShGitHubContract {
    static let apiMaximumBytes = 8 * 1_024 * 1_024
    static let archiveMaximumBytes = 128 * 1_024 * 1_024
    static let maximumTreeEntries = 100_000
    static let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")

    struct Input {
        let owner: String
        let repository: String
        let skillID: String
        let slug: DefaultDistributionSlug
        let alias: String
    }

    struct RepositoryResponse: Decodable {
        let fullName: String
        let isPrivate: Bool
        let defaultBranch: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case isPrivate = "private"
            case defaultBranch = "default_branch"
        }
    }

    struct CommitResponse: Decodable {
        struct Commit: Decodable {
            struct Tree: Decodable { let sha: String }
            let tree: Tree
        }

        let sha: String
        let commit: Commit
    }

    struct TreeResponse: Decodable {
        struct Entry: Decodable {
            let path: String
            let mode: String
            let type: String
            let sha: String
            let size: Int?
        }

        let sha: String
        let tree: [Entry]
        let truncated: Bool
    }

    struct TreeEntry {
        let path: String
        let components: [String]
        let mode: String
        let type: String
        let sha: String
        let size: Int?
    }

    static func input(
        id: String,
        source: String,
        skillID rawSkillID: String
    ) throws -> Input {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw SkillsShGitHubSourceError.invalidSource }
        let owner = String(parts[0])
        let repository = String(parts[1])
        guard validOwner(owner), validRepository(repository) else {
            throw SkillsShGitHubSourceError.invalidSource
        }

        let skillID = rawSkillID.precomposedStringWithCanonicalMapping
        guard !skillID.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }), !skillID.contains("%"),
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= 512,
              !id.contains("\0"),
              !id.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SkillsShGitHubSourceError.invalidSource
        }
        let slug: DefaultDistributionSlug
        do {
            slug = try DefaultDistributionSlug(validating: skillID)
        } catch {
            throw SkillsShGitHubSourceError.invalidSource
        }
        let alias = try canonicalAlias(id: id, source: source, skillID: skillID)
        return Input(
            owner: owner,
            repository: repository,
            skillID: skillID,
            slug: slug,
            alias: alias
        )
    }

    static func repository(
        _ input: Input,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> RepositoryResponse {
        try await repository(owner: input.owner, repository: input.repository, load: load)
    }

    static func repository(
        owner: String,
        repository: String,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> RepositoryResponse {
        let request = try apiRequest(path: ["repos", owner, repository])
        let response: RepositoryResponse = try await json(request, load: load)
        guard !response.isPrivate,
              asciiEqual(response.fullName, "\(owner)/\(repository)"),
              validDefaultBranch(response.defaultBranch) else {
            throw SkillsShGitHubSourceError.repositoryUnavailable
        }
        return response
    }

    static func commit(
        _ input: Input,
        defaultBranch: String,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> CommitResponse {
        try await commit(
            owner: input.owner,
            repository: input.repository,
            defaultBranch: defaultBranch,
            load: load
        )
    }

    static func commit(
        owner: String,
        repository: String,
        defaultBranch: String,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> CommitResponse {
        let request = try apiRequest(path: [
            "repos", owner, repository, "commits", defaultBranch,
        ])
        let response: CommitResponse = try await json(request, load: load)
        guard validSHA(response.sha), validSHA(response.commit.tree.sha) else {
            throw SkillsShGitHubSourceError.contractChanged
        }
        return response
    }

    static func source(
        _ input: Input,
        canonicalFullName: String,
        defaultBranch: String,
        commit: CommitResponse,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> SkillsShResolvedGitHubSource {
        let entries = try await treeEntries(
            owner: input.owner,
            repository: input.repository,
            treeSHA: commit.commit.tree.sha,
            load: load
        )
        let (subpath, blobs) = try target(in: entries, skillID: input.skillID)
        let canonical = canonicalFullName.split(separator: "/", omittingEmptySubsequences: false)
        guard canonical.count == 2 else { throw SkillsShGitHubSourceError.contractChanged }
        let owner = String(canonical[0])
        let repository = String(canonical[1])
        let repositoryURL: NormalizedRepositoryURL
        do {
            repositoryURL = try NormalizedRepositoryURL("https://github.com/\(owner)/\(repository)")
        } catch {
            throw SkillsShGitHubSourceError.contractChanged
        }
        return SkillsShResolvedGitHubSource(
            repositoryURL: repositoryURL,
            owner: owner,
            repository: repository,
            defaultBranch: defaultBranch,
            commitSHA: commit.sha,
            treeSHA: commit.commit.tree.sha,
            subpath: subpath,
            blobs: blobs,
            archiveURL: try apiURL(path: [
                "repos", owner, repository, "zipball", commit.sha,
            ]),
            providerAliasIdentifier: input.alias,
            defaultDistributionSlug: input.slug
        )
    }

    static func treeEntries(
        owner: String,
        repository: String,
        treeSHA: String,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> [TreeEntry] {
        let request = try apiRequest(
            path: ["repos", owner, repository, "git", "trees", treeSHA],
            queryItems: [URLQueryItem(name: "recursive", value: "1")]
        )
        let response: TreeResponse = try await json(request, load: load)
        guard !response.truncated else { throw SkillsShGitHubSourceError.treeTruncated }
        guard response.sha == treeSHA,
              response.tree.count <= maximumTreeEntries else {
            throw SkillsShGitHubSourceError.contractChanged
        }
        return try validatedEntries(response.tree)
    }

    static func archive(
        owner: String,
        repository: String,
        commitSHA: String,
        archiveURL: URL,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> SkillsShGitHubArchive {
        let firstRequest = request(url: archiveURL, accept: "application/vnd.github+json", timeout: 60)
        let (_, firstResponse) = try await load(firstRequest, 0)
        try validateResponseURL(firstResponse, requestURL: archiveURL)
        try throwHTTPError(firstResponse, expectedStatus: 302)
        guard let location = firstResponse.value(forHTTPHeaderField: "Location"),
              let codeloadURL = URL(string: location),
              validCodeloadURL(
                codeloadURL,
                owner: owner,
                repository: repository,
                commitSHA: commitSHA
              ) else {
            throw SkillsShGitHubSourceError.contractChanged
        }

        let secondRequest = request(url: codeloadURL, accept: "application/zip", timeout: 60)
        let (data, secondResponse) = try await load(secondRequest, archiveMaximumBytes)
        try validateResponseURL(secondResponse, requestURL: codeloadURL)
        try throwHTTPError(secondResponse, expectedStatus: 200)
        guard baseMIME(secondResponse) == "application/zip" else {
            throw SkillsShGitHubSourceError.contractChanged
        }
        return SkillsShGitHubArchive(data: data, sourceURL: archiveURL)
    }

    static func stable(_ error: Error) -> SkillsShGitHubSourceError {
        if let stable = error as? SkillsShGitHubSourceError { return stable }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            return switch error.code {
            case .cancelled: .cancelled
            case .timedOut: .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                .offline
            default: .network
            }
        }
        return .network
    }

    private static func json<Value: Decodable>(
        _ request: URLRequest,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> Value {
        try Task.checkCancellation()
        let (data, response) = try await load(request, apiMaximumBytes)
        try Task.checkCancellation()
        try validateResponseURL(response, requestURL: request.url)
        try throwHTTPError(response, expectedStatus: 200)
        guard ["application/json", "application/vnd.github+json"].contains(baseMIME(response)) else {
            throw SkillsShGitHubSourceError.contractChanged
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw SkillsShGitHubSourceError.contractChanged
        }
    }

}
