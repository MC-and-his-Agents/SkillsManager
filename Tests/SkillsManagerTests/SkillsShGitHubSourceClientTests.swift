import Foundation
import Testing

@testable import SkillsManager

@Suite("skills.sh GitHub source client")
struct SkillsShGitHubSourceClientTests {
    private let commitSHA = String(repeating: "a", count: 40)
    private let treeSHA = String(repeating: "b", count: 40)
    private let blobSHA = String(repeating: "c", count: 40)

    @Test("resolves one exact Skill and freezes target blob evidence")
    func resolve() async throws {
        let client = client(tree: validTree())
        let source = try await client.resolve("catalog/demo", "Owner/Repo", "demo")

        #expect(source.repositoryURL.value == "https://github.com/owner/repo")
        #expect(source.owner == "Owner")
        #expect(source.repository == "Repo")
        #expect(source.defaultBranch == "feature/one")
        #expect(source.commitSHA == commitSHA)
        #expect(source.treeSHA == treeSHA)
        #expect(source.subpath.value == "skills/demo")
        #expect(source.archiveURL.absoluteString ==
            "https://api.github.com/repos/Owner/Repo/zipball/\(commitSHA)")
        #expect(source.providerAliasIdentifier ==
            #"{"id":"catalog/demo","skillId":"demo","source":"Owner/Repo"}"#)
        #expect(source.defaultDistributionSlug.value == "demo")
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
    }

    @Test(
        "rejects invalid source and skill identifiers before networking",
        arguments: [
            ("owner/repo/extra", "demo"),
            ("-owner/repo", "demo"),
            ("owner-/repo", "demo"),
            ("owner/..", "demo"),
            ("owner/r%epo", "demo"),
            ("owner/repo", ".hidden"),
            ("owner/repo", "a/b"),
            ("owner/repo", "bad%name"),
            ("owner/repo", "bad\nname"),
        ]
    )
    func invalidInput(source: String, skillID: String) async {
        let client = SkillsShGitHubSourceClient.live { _, _ in
            Issue.record("network loader must not be called")
            throw URLError(.badServerResponse)
        }
        await #expect(throws: SkillsShGitHubSourceError.invalidSource) {
            _ = try await client.resolve("catalog/demo", source, skillID)
        }
    }

    @Test("encodes default branch as one URL path parameter and fixes API headers")
    func fixedRequests() async throws {
        let recorder = RequestRecorder()
        let client = client(tree: validTree(), recorder: recorder)
        _ = try await client.resolve("catalog/demo", "Owner/Repo", "demo")
        let requests = await recorder.values

        #expect(requests.count == 3)
        #expect(requests[0].0.url?.absoluteString == "https://api.github.com/repos/Owner/Repo")
        #expect(requests[1].0.url?.absoluteString ==
            "https://api.github.com/repos/Owner/Repo/commits/feature%2Fone")
        #expect(requests[2].0.url?.absoluteString ==
            "https://api.github.com/repos/Owner/Repo/git/trees/\(treeSHA)?recursive=1")
        for (request, maximumBytes) in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "SkillsManager/0.1.0")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.timeoutInterval == 10)
            #expect(maximumBytes == 8 * 1_024 * 1_024)
        }
    }

    enum MatchFailure: CaseIterable {
        case zero
        case multiple
        case root

        var tree: [[String: Any]] {
            switch self {
            case .zero:
                [treeEntry("skills/other", mode: "040000", type: "tree", size: nil),
                 treeEntry("skills/other/SKILL.md")]
            case .multiple:
                [treeEntry("a/demo", mode: "040000", type: "tree", size: nil),
                 treeEntry("a/demo/SKILL.md"),
                 treeEntry("b/demo", mode: "040000", type: "tree", size: nil),
                 treeEntry("b/demo/SKILL.md")]
            case .root:
                [treeEntry("SKILL.md")]
            }
        }
    }

    @Test(
        "fails closed for zero, multiple, and root matches",
        arguments: MatchFailure.allCases
    )
    func matchFailures(_ fixture: MatchFailure) async {
        let client = client(tree: fixture.tree)
        await #expect(throws: SkillsShGitHubSourceError.noUniqueSkillMatch) {
            _ = try await client.resolve("catalog/demo", "owner/repo", "demo")
        }
    }

    enum TreeContractFailure: CaseIterable {
        case duplicate
        case collision
        case prefixConflict
        case symlink
        case submodule
        case invalidMode

        var tree: [[String: Any]] {
            var entries = SkillsShGitHubSourceClientTests().validTree()
            switch self {
            case .duplicate:
                entries.append(treeEntry("skills/demo/SKILL.md"))
            case .collision:
                entries.append(treeEntry("skills/demo/skill.md"))
            case .prefixConflict:
                entries.append(treeEntry("blocked", mode: "100644", type: "blob"))
                entries.append(treeEntry("blocked/file.md"))
            case .symlink:
                entries.append(treeEntry("skills/demo/link", mode: "120000", type: "blob"))
            case .submodule:
                entries.append(treeEntry("skills/demo/module", mode: "160000", type: "commit", size: nil))
            case .invalidMode:
                entries.append(treeEntry("skills/demo/device", mode: "100600", type: "blob"))
            }
            return entries
        }
    }

    @Test(
        "rejects ambiguous paths and non-regular target entries",
        arguments: TreeContractFailure.allCases
    )
    func treeFailures(_ fixture: TreeContractFailure) async {
        let client = client(tree: fixture.tree)
        await #expect(throws: SkillsShGitHubSourceError.contractChanged) {
            _ = try await client.resolve("catalog/demo", "owner/repo", "demo")
        }
    }

    @Test("rejects truncated tree and malformed commit SHA")
    func truncatedAndSHA() async {
        await #expect(throws: SkillsShGitHubSourceError.treeTruncated) {
            _ = try await client(tree: validTree(), truncated: true)
                .resolve("catalog/demo", "owner/repo", "demo")
        }
        await #expect(throws: SkillsShGitHubSourceError.contractChanged) {
            _ = try await client(tree: validTree(), commitSHA: "ABC")
                .resolve("catalog/demo", "owner/repo", "demo")
        }
    }

    enum HTTPFailure: CaseIterable {
        case forbidden
        case limited
        case missing
        case unavailable
        case redirected

        var status: Int {
            switch self {
            case .forbidden: 403
            case .limited: 429
            case .missing: 404
            case .unavailable: 503
            case .redirected: 301
            }
        }

        var error: SkillsShGitHubSourceError {
            switch self {
            case .forbidden, .limited: .rateLimited
            case .missing: .repositoryUnavailable
            case .unavailable: .providerUnavailable
            case .redirected: .contractChanged
            }
        }
    }

    @Test("maps GitHub HTTP failures without returning bodies", arguments: HTTPFailure.allCases)
    func httpFailures(_ fixture: HTTPFailure) async {
        let client = SkillsShGitHubSourceClient.live { request, _ in
            (Data("<html>secret</html>".utf8), try response(request.url, status: fixture.status))
        }
        await #expect(throws: fixture.error) {
            _ = try await client.resolve("catalog/demo", "owner/repo", "demo")
        }
    }

    @Test("maps transport failures and cancellation")
    func transportFailures() async {
        let cases: [(URLError.Code, SkillsShGitHubSourceError)] = [
            (.timedOut, .timeout),
            (.notConnectedToInternet, .offline),
            (.networkConnectionLost, .offline),
            (.badServerResponse, .network),
            (.cancelled, .cancelled),
        ]
        for (code, expected) in cases {
            let client = SkillsShGitHubSourceClient.live { _, _ in throw URLError(code) }
            await #expect(throws: expected) {
                _ = try await client.resolve("catalog/demo", "owner/repo", "demo")
            }
        }
    }

    @Test("rejects unexpected MIME and response URL")
    func responseBinding() async {
        let wrongMIME = SkillsShGitHubSourceClient.live { request, _ in
            (Data("{}".utf8), try response(request.url, contentType: "text/html"))
        }
        await #expect(throws: SkillsShGitHubSourceError.contractChanged) {
            _ = try await wrongMIME.resolve("catalog/demo", "owner/repo", "demo")
        }

        let wrongURL = SkillsShGitHubSourceClient.live { _, _ in
            let url = try #require(URL(string: "https://evil.example/"))
            return (Data("{}".utf8), try response(url))
        }
        await #expect(throws: SkillsShGitHubSourceError.contractChanged) {
            _ = try await wrongURL.resolve("catalog/demo", "owner/repo", "demo")
        }
    }

    @Test("re-reads repository metadata and the encoded default-branch commit")
    func currentCommit() async throws {
        let recorder = RequestRecorder()
        let source = try resolvedSource()
        let client = client(tree: validTree(), recorder: recorder)

        #expect(try await client.currentCommitSHA(source) == commitSHA)
        let requests = await recorder.values
        #expect(requests.map { $0.0.url?.absoluteString } == [
            "https://api.github.com/repos/Owner/Repo",
            "https://api.github.com/repos/Owner/Repo/commits/feature%2Fone",
        ])
    }

    @Test("expires a resolved source when the default branch changes")
    func changedDefaultBranch() async throws {
        let source = try resolvedSource()
        let client = client(tree: validTree(), defaultBranch: "main")

        await #expect(throws: SkillsShGitHubSourceError.repositoryUnavailable) {
            _ = try await client.currentCommitSHA(source)
        }
    }

    @Test("downloads only through one exact codeload redirect")
    func archive() async throws {
        let source = try resolvedSource()
        let recorder = RequestRecorder()
        let zip = Data([0x50, 0x4B, 0x03, 0x04])
        let client = SkillsShGitHubSourceClient.live { request, maximumBytes in
            await recorder.append(request, maximumBytes)
            let url = try #require(request.url)
            if url.host == "api.github.com" {
                return (
                    Data(),
                    try response(
                        url,
                        status: 302,
                        headers: [
                            "Location":
                                "https://codeload.github.com/Owner/Repo/legacy.zip/\(commitSHA)",
                        ]
                    )
                )
            }
            return (zip, try response(url, contentType: "application/zip"))
        }

        let archive = try await client.download(source)

        #expect(archive.data == zip)
        #expect(archive.sourceURL == source.archiveURL)
        let requests = await recorder.values
        #expect(requests.count == 2)
        #expect(requests[0].1 == 0)
        #expect(requests[1].1 == 128 * 1_024 * 1_024)
        #expect(requests[1].0.url?.absoluteString ==
            "https://codeload.github.com/Owner/Repo/legacy.zip/\(commitSHA)")
        #expect(requests[1].0.value(forHTTPHeaderField: "Accept") == "application/zip")
        #expect(requests[1].0.timeoutInterval == 60)
    }

    @Test(
        "rejects malformed codeload redirects",
        arguments: [
            "http://codeload.github.com/Owner/Repo/legacy.zip/",
            "https://evil.example/Owner/Repo/legacy.zip/",
            "https://codeload.github.com/Owner/Other/legacy.zip/",
            "https://codeload.github.com/Owner/Repo/legacy.zip/",
            "https://codeload.github.com/Owner/Repo/legacy.zip/%61",
            "https://codeload.github.com/Owner/Repo/legacy.zip/",
        ]
    )
    func archiveRedirect(prefix: String) async throws {
        let source = try resolvedSource()
        let location = prefix + commitSHA + (prefix.hasSuffix("%61") ? "" : "?bad=1")
        let client = SkillsShGitHubSourceClient.live { request, _ in
            (Data(), try response(request.url, status: 302, headers: ["Location": location]))
        }
        await #expect(throws: SkillsShGitHubSourceError.contractChanged) {
            _ = try await client.download(source)
        }
    }

    @Test("rejects a second redirect and non-zip archive")
    func archiveResponse() async throws {
        let source = try resolvedSource()
        for (status, mime) in [(302, "application/zip"), (200, "text/html")] {
            let client = SkillsShGitHubSourceClient.live { request, _ in
                let url = try #require(request.url)
                if url.host == "api.github.com" {
                    return (
                        Data(),
                        try response(
                            url,
                            status: 302,
                            headers: [
                                "Location":
                                    "https://codeload.github.com/Owner/Repo/legacy.zip/\(commitSHA)",
                            ]
                        )
                    )
                }
                return (Data(), try response(url, status: status, contentType: mime))
            }
            await #expect(throws: SkillsShGitHubSourceError.contractChanged) {
                _ = try await client.download(source)
            }
        }
    }

    @Test("transport enforces declared and streamed response limits")
    func responseLimit() async {
        await #expect(throws: SkillsShGitHubSourceError.responseTooLarge) {
            _ = try await SkillsShGitHubHTTPTransport.collect(
                byteStream([]),
                expectedLength: 2,
                maximumBytes: 1
            )
        }
        await #expect(throws: SkillsShGitHubSourceError.responseTooLarge) {
            _ = try await SkillsShGitHubHTTPTransport.collect(
                byteStream([1, 2]),
                expectedLength: -1,
                maximumBytes: 1
            )
        }
    }

    private func client(
        tree: [[String: Any]],
        truncated: Bool = false,
        commitSHA: String? = nil,
        defaultBranch: String = "feature/one",
        recorder: RequestRecorder? = nil
    ) -> SkillsShGitHubSourceClient {
        let commitSHA = commitSHA ?? self.commitSHA
        let treeSHA = self.treeSHA
        let treeData = (try? JSONSerialization.data(
            withJSONObject: ["sha": treeSHA, "tree": tree, "truncated": truncated],
            options: [.sortedKeys]
        )) ?? Data()
        return SkillsShGitHubSourceClient.live { request, maximumBytes in
            if let recorder { await recorder.append(request, maximumBytes) }
            let url = try #require(request.url)
            let data: Data
            if url.path == "/repos/Owner/Repo" || url.path == "/repos/owner/repo" {
                data = Data(
                    #"{"default_branch":"\#(defaultBranch)","full_name":"Owner/Repo","private":false}"#.utf8
                )
            } else if url.path.contains("/commits/") {
                #expect(url.absoluteString.contains("/commits/feature%2Fone"))
                data = Data(
                    #"{"commit":{"tree":{"sha":"\#(treeSHA)"}},"sha":"\#(commitSHA)"}"#.utf8
                )
            } else {
                #expect(url.path.contains("/git/trees/\(treeSHA)"))
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ==
                    [URLQueryItem(name: "recursive", value: "1")])
                data = treeData
            }
            return (data, try response(url))
        }
    }

    private func validTree() -> [[String: Any]] {
        [
            treeEntry("skills", mode: "040000", type: "tree", size: nil),
            treeEntry("skills/demo", mode: "040000", type: "tree", size: nil),
            treeEntry("skills/demo/SKILL.md", size: 12, sha: blobSHA),
            treeEntry("skills/demo/notes", mode: "040000", type: "tree", size: nil),
            treeEntry(
                "skills/demo/notes/readme.md",
                mode: "100755",
                size: 3,
                sha: String(repeating: "d", count: 40)
            ),
            treeEntry("other", mode: "040000", type: "tree", size: nil),
            treeEntry("other/link", mode: "120000", type: "blob", size: 8),
            treeEntry("other/module", mode: "160000", type: "commit", size: nil),
        ]
    }

    private func resolvedSource() throws -> SkillsShResolvedGitHubSource {
        SkillsShResolvedGitHubSource(
            repositoryURL: try NormalizedRepositoryURL("https://github.com/Owner/Repo"),
            owner: "Owner",
            repository: "Repo",
            defaultBranch: "feature/one",
            commitSHA: commitSHA,
            treeSHA: treeSHA,
            subpath: try RepositorySubpath("skills/demo"),
            blobs: [],
            archiveURL: try #require(URL(
                string: "https://api.github.com/repos/Owner/Repo/zipball/\(commitSHA)"
            )),
            providerAliasIdentifier:
                #"{"id":"Owner/Repo/demo","skillId":"demo","source":"Owner/Repo"}"#,
            defaultDistributionSlug: try DefaultDistributionSlug(validating: "demo")
        )
    }

    private func response(
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

    private func byteStream(_ bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream<UInt8>(bufferingPolicy: .unbounded) { continuation in
            for byte in bytes {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }
}

private nonisolated func treeEntry(
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

private actor RequestRecorder {
    private(set) var values: [(URLRequest, Int)] = []

    func append(_ request: URLRequest, _ maximumBytes: Int) {
        values.append((request, maximumBytes))
    }
}
