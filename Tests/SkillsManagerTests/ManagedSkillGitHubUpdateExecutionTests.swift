import CryptoKit
import Foundation
import Testing
import ZIPFoundation

@testable import SkillsManager

@Suite("Managed GitHub Skill update execution", .serialized)
struct ManagedSkillGitHubUpdateExecutionTests {
    @Test("updates the exact stored repository subpath and immutable revision")
    func updatesExactGitHubSource() async throws {
        let workspace = try WriterWorkspace()
        let writer = try await workspace.openWriter()
        let original = try workspace.snapshot(content: "# Original")
        let skillID = SkillID()
        let sourceID = SourceID()
        let repositoryURL = try NormalizedRepositoryURL(
            "https://github.com/example/repository"
        )
        let subpath = try RepositorySubpath("skills/demo")
        let alias = try ProviderAliasIdentity(
            provider: "skills.sh",
            identifier: "example/repository:demo"
        )
        let payload = try SSOTSkillWritePayload(
            skill: workspace.payload(
                skillID: skillID,
                name: "Demo",
                snapshot: original
            ).skill,
            source: SkillSourceRecord(
                sourceID: sourceID,
                skillID: skillID,
                repositoryURL: repositoryURL,
                subpath: subpath,
                revision: try SourceRevision(String(repeating: "a", count: 40)),
                downloadURL: try PublicDownloadURL(
                    "https://codeload.github.com/example/repository/legacy.zip/"
                        + String(repeating: "a", count: 40)
                )
            ),
            providerAliases: [
                ProviderAliasRecord(sourceID: sourceID, identity: alias),
            ]
        )
        _ = try await writer.create(payload: payload, sourceSnapshot: original)
        let github = try githubUpdateClient(markdown: "# Remote")
        let remote = unusedRemoteClient()
        let checks = ManagedSkillUpdateCheckService(
            writer: writer,
            remote: remote,
            github: github
        )
        let snapshot = try await checks.check(skillID)
        let service = ManagedSkillUpdateExecutionService(
            writer: writer,
            remote: remote,
            github: github
        )

        let preview = try await service.prepare(snapshot)
        let result = try await service.confirm(preview.token, selections: [])

        #expect(result.status == .updated)
        let current = try #require(try await writer.storedDomainReadback(skillID))
        #expect(current.payload.source?.repositoryURL == repositoryURL)
        #expect(current.payload.source?.subpath == subpath)
        #expect(
            current.payload.source?.revision
                == (try SourceRevision(String(repeating: "b", count: 40)))
        )
        #expect(try await writer.loadUpdateCheck(skillID)?.status == .upToDate)
    }
}

private func githubUpdateClient(
    markdown: String
) throws -> SkillsShGitHubSourceClient {
    let commitSHA = String(repeating: "b", count: 40)
    let treeSHA = String(repeating: "c", count: 40)
    let contents = Data(markdown.utf8)
    let blobSHA = gitBlobSHA(contents)
    let archiveData = try githubUpdateArchive(contents)
    let treeData = try JSONSerialization.data(
        withJSONObject: [
            "sha": treeSHA,
            "truncated": false,
            "tree": [
                [
                    "path": "skills",
                    "mode": "040000",
                    "type": "tree",
                    "sha": String(repeating: "d", count: 40),
                ],
                [
                    "path": "skills/demo",
                    "mode": "040000",
                    "type": "tree",
                    "sha": String(repeating: "e", count: 40),
                ],
                [
                    "path": "skills/demo/SKILL.md",
                    "mode": "100644",
                    "type": "blob",
                    "sha": blobSHA,
                    "size": contents.count,
                ],
            ],
        ],
        options: [.sortedKeys]
    )
    return SkillsShGitHubSourceClient.live { request, _ in
        let url = try #require(request.url)
        if url.host == "codeload.github.com" {
            return (
                archiveData,
                try githubUpdateResponse(url, contentType: "application/zip")
            )
        }
        if url.path == "/repos/example/repository" {
            return (
                Data(
                    #"{"default_branch":"main","full_name":"example/repository","private":false}"#.utf8
                ),
                try githubUpdateResponse(url)
            )
        }
        if url.path.contains("/commits/") {
            return (
                Data(
                    #"{"commit":{"tree":{"sha":"\#(treeSHA)"}},"sha":"\#(commitSHA)"}"#.utf8
                ),
                try githubUpdateResponse(url)
            )
        }
        if url.path.contains("/git/trees/") {
            return (treeData, try githubUpdateResponse(url))
        }
        if url.path.contains("/zipball/") {
            return (
                Data(),
                try githubUpdateResponse(
                    url,
                    status: 302,
                    headers: [
                        "Location":
                            "https://codeload.github.com/example/repository/legacy.zip/\(commitSHA)",
                    ]
                )
            )
        }
        throw URLError(.badURL)
    }
}

private func githubUpdateArchive(_ contents: Data) throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("github-update-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    let archive = try Archive(url: url, accessMode: .create)
    try archive.addEntry(
        with: "wrapper/skills/demo/SKILL.md",
        type: .file,
        uncompressedSize: Int64(contents.count),
        permissions: 0o644
    ) { position, size in
        let start = Int(position)
        return contents.subdata(in: start..<min(start + size, contents.count))
    }
    return try Data(contentsOf: url)
}

private func gitBlobSHA(_ contents: Data) -> String {
    var hasher = Insecure.SHA1()
    hasher.update(data: Data("blob \(contents.count)\0".utf8))
    hasher.update(data: contents)
    return Data(hasher.finalize()).map {
        String(format: "%02x", $0)
    }.joined()
}

private func githubUpdateResponse(
    _ url: URL,
    status: Int = 200,
    contentType: String = "application/json",
    headers: [String: String] = [:]
) throws -> HTTPURLResponse {
    var fields = headers
    fields["Content-Type"] = contentType
    return try #require(HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: fields
    ))
}

private func unusedRemoteClient() -> RemoteSkillClient {
    RemoteSkillClient(
        fetchLatest: { _ in [] },
        search: { _, _ in [] },
        download: { _, _ in throw URLError(.unsupportedURL) },
        fetchDetail: { _ in nil },
        fetchLatestVersion: { _ in nil }
    )
}
