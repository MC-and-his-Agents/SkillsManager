import Foundation
import Testing

@testable import SkillsManager

@Suite("skills.sh existing GitHub source client")
struct SkillsShGitHubSourceClientExistingTests {
    private let commitSHA = String(repeating: "a", count: 40)
    private let treeSHA = String(repeating: "b", count: 40)
    private let blobSHA = String(repeating: "c", count: 40)

    @Test("resolves by collision-normalized exact repository subpath")
    func resolveExisting() async throws {
        let recorder = ExistingSourceRequestRecorder()
        var tree = validTree()
        tree.append(existingTreeEntry("elsewhere", mode: "040000", type: "tree", size: nil))
        tree.append(existingTreeEntry(
            "elsewhere/demo",
            mode: "040000",
            type: "tree",
            size: nil
        ))
        tree.append(existingTreeEntry("elsewhere/demo/SKILL.md"))
        tree.append(existingTreeEntry(
            "skills/other",
            mode: "040000",
            type: "tree",
            size: nil
        ))
        tree.append(existingTreeEntry("skills/other/SKILL.md"))
        let repositoryURL = try NormalizedRepositoryURL("https://github.com/Owner/Repo")
        let subpath = try RepositorySubpath("SKILLS/DEMO")

        let source = try await client(tree: tree, recorder: recorder)
            .resolveExisting(repositoryURL, subpath)

        #expect(source.repositoryURL == repositoryURL)
        #expect(source.owner == "Owner")
        #expect(source.repository == "Repo")
        #expect(source.defaultBranch == "feature/one")
        #expect(source.commitSHA == commitSHA)
        #expect(source.treeSHA == treeSHA)
        #expect(source.subpath == subpath)
        #expect(source.archiveURL.absoluteString ==
            "https://api.github.com/repos/Owner/Repo/zipball/\(commitSHA)")
        #expect(source.blobs == [
            SkillsShGitHubBlob(
                relativePath: "SKILL.md",
                mode: "100644",
                size: 12,
                gitBlobSHA: blobSHA
            ),
            SkillsShGitHubBlob(
                relativePath: "notes/readme.md",
                mode: "100755",
                size: 3,
                gitBlobSHA: String(repeating: "d", count: 40)
            ),
        ])
        #expect(await recorder.values.map { $0.url?.absoluteString } == [
            "https://api.github.com/repos/owner/repo",
            "https://api.github.com/repos/owner/repo/commits/feature%2Fone",
            "https://api.github.com/repos/owner/repo/git/trees/\(treeSHA)?recursive=1",
        ])
    }

    @Test("resolves a repository-root Skill")
    func resolveRoot() async throws {
        let source = try await client(tree: [
            existingTreeEntry("SKILL.md", size: 12, sha: blobSHA),
            existingTreeEntry("README.md", size: 3),
        ]).resolveExisting(
            NormalizedRepositoryURL("https://github.com/owner/repo"),
            RepositorySubpath("")
        )

        #expect(source.subpath.value.isEmpty)
        #expect(source.blobs.map(\.relativePath) == ["README.md", "SKILL.md"])
    }

    @Test("fails closed when the stored subpath has no exact Skill")
    func missingExistingSubpath() async throws {
        let repositoryURL = try NormalizedRepositoryURL("https://github.com/owner/repo")

        await #expect(throws: SkillsShGitHubSourceError.noUniqueSkillMatch) {
            _ = try await client(tree: validTree()).resolveExisting(
                repositoryURL,
                try RepositorySubpath("elsewhere/demo")
            )
        }
    }

    @Test("rejects non-GitHub identity before networking")
    func invalidExistingRepository() async throws {
        let client = SkillsShGitHubSourceClient.live { _, _ in
            Issue.record("network loader must not be called")
            throw URLError(.badServerResponse)
        }
        let repositoryURL = try NormalizedRepositoryURL("https://example.com/owner/repo")

        await #expect(throws: SkillsShGitHubSourceError.invalidSource) {
            _ = try await client.resolveExisting(
                repositoryURL,
                try RepositorySubpath("skills/demo")
            )
        }
    }

    @Test("downloads through the fixed archive contract")
    func existingArchive() async throws {
        let repositoryURL = try NormalizedRepositoryURL("https://github.com/Owner/Repo")
        let resolved = try await client(tree: validTree()).resolveExisting(
            repositoryURL,
            RepositorySubpath("skills/demo")
        )
        let zip = Data([0x50, 0x4B, 0x03, 0x04])
        let downloadClient = SkillsShGitHubSourceClient.live { request, _ in
            let url = try #require(request.url)
            if url.host == "api.github.com" {
                return (
                    Data(),
                    try existingResponse(
                        url,
                        status: 302,
                        headers: [
                            "Location":
                                "https://codeload.github.com/Owner/Repo/legacy.zip/\(commitSHA)",
                        ]
                    )
                )
            }
            return (zip, try existingResponse(url, contentType: "application/zip"))
        }

        #expect(try await downloadClient.downloadExisting(resolved) ==
            SkillsShGitHubArchive(data: zip, sourceURL: resolved.archiveURL))
    }

    @Test("keeps GitHub 5xx transient instead of treating the source as missing")
    func providerUnavailable() async throws {
        let client = SkillsShGitHubSourceClient.live { request, _ in
            (
                Data(),
                try existingResponse(request.url, status: 503)
            )
        }

        await #expect(throws: SkillsShGitHubSourceError.providerUnavailable) {
            _ = try await client.resolveExisting(
                NormalizedRepositoryURL("https://github.com/owner/repo"),
                RepositorySubpath("skills/demo")
            )
        }
    }

    @Test("resolves a custom repository snapshot only through its immutable commit")
    func resolveCustomRepositorySnapshot() async throws {
        let recorder = ExistingSourceRequestRecorder()
        let source = try await customClient(tree: validTree(), recorder: recorder)
            .resolveCustomRepository(try snapshot(subpath: "skills/demo"))
        let repositoryURL = try NormalizedRepositoryURL("https://github.com/owner/repo")
        let subpath = try RepositorySubpath("skills/demo")

        #expect(source.repositoryURL == repositoryURL)
        #expect(source.commitSHA == commitSHA)
        #expect(source.defaultBranch == commitSHA)
        #expect(source.subpath == subpath)
        #expect(source.blobs.map(\.relativePath) == ["SKILL.md", "notes/readme.md"])
        #expect(source.archiveURL.absoluteString ==
            "https://api.github.com/repos/owner/repo/zipball/\(commitSHA)")
        #expect(await recorder.values.map { $0.url?.absoluteString } == [
            "https://api.github.com/repos/owner/repo/commits/\(commitSHA)",
            "https://api.github.com/repos/owner/repo/git/trees/\(treeSHA)?recursive=1",
        ])
    }

    @Test("resolves an exact repository-root snapshot")
    func resolveCustomRepositoryRoot() async throws {
        let source = try await customClient(tree: [
            existingTreeEntry("SKILL.md", size: 12, sha: blobSHA),
            existingTreeEntry("README.md", size: 3),
        ]).resolveCustomRepository(try snapshot(subpath: ""))

        #expect(source.subpath.value.isEmpty)
        #expect(source.blobs.map(\.relativePath) == ["README.md", "SKILL.md"])
    }

    @Test("fails closed when immutable identity or exact target changes")
    func customRepositorySnapshotDrift() async throws {
        let mismatchedCommit = SkillsShGitHubSourceClient.live { request, _ in
            let url = try #require(request.url)
            return (
                Data(
                    #"{"commit":{"tree":{"sha":"\#(treeSHA)"}},"sha":"\#(String(repeating: "f", count: 40))"}"#.utf8
                ),
                try existingResponse(url)
            )
        }
        await #expect(throws: SkillsShGitHubSourceError.contractChanged) {
            _ = try await mismatchedCommit.resolveCustomRepository(
                try snapshot(subpath: "skills/demo")
            )
        }

        await #expect(throws: SkillsShGitHubSourceError.noUniqueSkillMatch) {
            _ = try await customClient(tree: validTree()).resolveCustomRepository(
                try snapshot(subpath: "skills/missing")
            )
        }

        var ambiguous = validTree()
        ambiguous.append(existingTreeEntry("skills/demo/skill.md"))
        await #expect(throws: SkillsShGitHubSourceError.contractChanged) {
            _ = try await customClient(tree: ambiguous).resolveCustomRepository(
                try snapshot(subpath: "skills/demo")
            )
        }
    }

    @Test("validates custom snapshot before networking and preserves typed failures")
    func customRepositoryFailures() async throws {
        let noNetwork = SkillsShGitHubSourceClient.live { _, _ in
            Issue.record("network loader must not be called")
            throw URLError(.badServerResponse)
        }
        var invalid = try snapshot(subpath: "skills/demo")
        invalid = CustomRepositoryInstallSnapshot(
            repositoryID: invalid.repositoryID,
            databaseRevision: invalid.databaseRevision,
            repositoryURL: invalid.repositoryURL,
            requestedRef: invalid.requestedRef,
            commitSHA: "main",
            subpath: invalid.subpath
        )
        await #expect(throws: SkillsShGitHubSourceError.invalidSource) {
            _ = try await noNetwork.resolveCustomRepository(invalid)
        }

        let timeout = SkillsShGitHubSourceClient.live { _, _ in throw URLError(.timedOut) }
        await #expect(throws: SkillsShGitHubSourceError.timeout) {
            _ = try await timeout.resolveCustomRepository(try snapshot(subpath: "skills/demo"))
        }

        let task = Task {
            try await SkillsShGitHubSourceClient.live { _, _ in
                try await Task.sleep(for: .seconds(1))
                throw URLError(.badServerResponse)
            }.resolveCustomRepository(try snapshot(subpath: "skills/demo"))
        }
        task.cancel()
        await #expect(throws: SkillsShGitHubSourceError.cancelled) {
            _ = try await task.value
        }
    }

    private func client(
        tree: [[String: Any]],
        recorder: ExistingSourceRequestRecorder? = nil
    ) -> SkillsShGitHubSourceClient {
        let treeData = (try? JSONSerialization.data(
            withJSONObject: ["sha": treeSHA, "tree": tree, "truncated": false],
            options: [.sortedKeys]
        )) ?? Data()
        return SkillsShGitHubSourceClient.live { request, _ in
            if let recorder { await recorder.append(request) }
            let url = try #require(request.url)
            let data: Data
            if url.path == "/repos/owner/repo" {
                data = Data(
                    #"{"default_branch":"feature/one","full_name":"Owner/Repo","private":false}"#.utf8
                )
            } else if url.path.contains("/commits/") {
                data = Data(
                    #"{"commit":{"tree":{"sha":"\#(treeSHA)"}},"sha":"\#(commitSHA)"}"#.utf8
                )
            } else {
                data = treeData
            }
            return (data, try existingResponse(url))
        }
    }

    private func customClient(
        tree: [[String: Any]],
        recorder: ExistingSourceRequestRecorder? = nil
    ) -> SkillsShGitHubSourceClient {
        let treeData = (try? JSONSerialization.data(
            withJSONObject: ["sha": treeSHA, "tree": tree, "truncated": false],
            options: [.sortedKeys]
        )) ?? Data()
        return SkillsShGitHubSourceClient.live { request, _ in
            if let recorder { await recorder.append(request) }
            let url = try #require(request.url)
            let data = url.path.contains("/commits/")
                ? Data(
                    #"{"commit":{"tree":{"sha":"\#(treeSHA)"}},"sha":"\#(commitSHA)"}"#.utf8
                )
                : treeData
            return (data, try existingResponse(url))
        }
    }

    private func snapshot(subpath: String) throws -> CustomRepositoryInstallSnapshot {
        CustomRepositoryInstallSnapshot(
            repositoryID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            databaseRevision: 4,
            repositoryURL: try NormalizedRepositoryURL("https://github.com/owner/repo"),
            requestedRef: try .explicit(validating: "release/v1"),
            commitSHA: commitSHA,
            subpath: try RepositorySubpath(subpath)
        )
    }

    private func validTree() -> [[String: Any]] {
        [
            existingTreeEntry("skills", mode: "040000", type: "tree", size: nil),
            existingTreeEntry("skills/demo", mode: "040000", type: "tree", size: nil),
            existingTreeEntry("skills/demo/SKILL.md", size: 12, sha: blobSHA),
            existingTreeEntry("skills/demo/notes", mode: "040000", type: "tree", size: nil),
            existingTreeEntry(
                "skills/demo/notes/readme.md",
                mode: "100755",
                size: 3,
                sha: String(repeating: "d", count: 40)
            ),
        ]
    }

    private func existingResponse(
        _ url: URL?,
        status: Int = 200,
        contentType: String = "application/json",
        headers extraHeaders: [String: String] = [:]
    ) throws -> HTTPURLResponse {
        let url = try #require(url)
        var headers = extraHeaders
        headers["Content-Type"] = contentType
        return try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ))
    }
}

private nonisolated func existingTreeEntry(
    _ path: String,
    mode: String = "100644",
    type: String = "blob",
    size: Int? = 1,
    sha: String = String(repeating: "e", count: 40)
) -> [String: Any] {
    var value: [String: Any] = ["path": path, "mode": mode, "type": type, "sha": sha]
    if let size { value["size"] = size }
    return value
}

private actor ExistingSourceRequestRecorder {
    private(set) var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        values.append(request)
    }
}
