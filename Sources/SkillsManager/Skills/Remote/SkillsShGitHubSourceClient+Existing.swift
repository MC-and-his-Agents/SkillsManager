import Foundation

nonisolated extension SkillsShGitHubContract {
    struct ExistingInput {
        let repositoryURL: NormalizedRepositoryURL
        let owner: String
        let repository: String
        let subpath: RepositorySubpath
    }

    static func existingInput(
        repositoryURL: NormalizedRepositoryURL,
        subpath: RepositorySubpath
    ) throws -> ExistingInput {
        guard let components = URLComponents(string: repositoryURL.value),
              components.scheme == "https",
              components.host == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw SkillsShGitHubSourceError.invalidSource
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2 else { throw SkillsShGitHubSourceError.invalidSource }
        let owner = String(path[0])
        let repository = String(path[1])
        guard validOwner(owner), validRepository(repository) else {
            throw SkillsShGitHubSourceError.invalidSource
        }
        return ExistingInput(
            repositoryURL: repositoryURL,
            owner: owner,
            repository: repository,
            subpath: subpath
        )
    }

    static func updateSource(
        _ input: ExistingInput,
        canonicalFullName: String,
        defaultBranch: String,
        commit: CommitResponse,
        load: SkillsShGitHubSourceClient.DataLoader
    ) async throws -> SkillsShResolvedGitHubUpdateSource {
        let entries = try await treeEntries(
            owner: input.owner,
            repository: input.repository,
            treeSHA: commit.commit.tree.sha,
            load: load
        )
        let blobs = try exactTarget(in: entries, subpath: input.subpath)
        let canonical = canonicalFullName.split(separator: "/", omittingEmptySubsequences: false)
        guard canonical.count == 2 else { throw SkillsShGitHubSourceError.contractChanged }
        let owner = String(canonical[0])
        let repository = String(canonical[1])
        let resolvedRepositoryURL: NormalizedRepositoryURL
        do {
            resolvedRepositoryURL = try NormalizedRepositoryURL(
                "https://github.com/\(owner)/\(repository)"
            )
        } catch {
            throw SkillsShGitHubSourceError.contractChanged
        }
        guard resolvedRepositoryURL == input.repositoryURL else {
            throw SkillsShGitHubSourceError.repositoryUnavailable
        }
        return SkillsShResolvedGitHubUpdateSource(
            repositoryURL: input.repositoryURL,
            owner: owner,
            repository: repository,
            defaultBranch: defaultBranch,
            commitSHA: commit.sha,
            treeSHA: commit.commit.tree.sha,
            subpath: input.subpath,
            blobs: blobs,
            archiveURL: try apiURL(path: [
                "repos", owner, repository, "zipball", commit.sha,
            ])
        )
    }
}
