import Foundation
import Testing

@testable import SkillsManager

@Suite("Custom repository discovery")
struct CustomRepositoryDiscoveryTests {
    @Test("enumerates root, siblings, and non-overlapping nested candidates")
    func layouts() throws {
        let repositoryURL = try NormalizedRepositoryURL("https://github.com/owner/repo")
        let root = try SkillsShGitHubContract.discoveryCandidates(
            [entry("SKILL.md")],
            repositoryURL: repositoryURL,
            repositoryName: "repo"
        )
        #expect(root.map(\.subpath.value) == [""])
        #expect(root.map(\.displayName) == ["repo"])

        let candidates = try SkillsShGitHubContract.discoveryCandidates(
            [entry("skills/a/SKILL.md"), entry("skills/b/SKILL.md"),
             entry("other/deep/c/SKILL.md")],
            repositoryURL: repositoryURL,
            repositoryName: "repo"
        )
        #expect(candidates.map(\.subpath.value) == [
            "other/deep/c", "skills/a", "skills/b",
        ])
        #expect(Set(candidates.map(\.providerAlias)).count == 3)
    }

    @Test("rejects root-child and parent-child layouts")
    func overlap() throws {
        let repositoryURL = try NormalizedRepositoryURL("https://github.com/owner/repo")
        for paths in [
            ["SKILL.md", "child/SKILL.md"],
            ["skills/SKILL.md", "skills/child/SKILL.md"],
        ] {
            #expect(throws: SkillsShGitHubSourceError.contractChanged) {
                try SkillsShGitHubContract.discoveryCandidates(
                    paths.map(entry),
                    repositoryURL: repositoryURL,
                    repositoryName: "repo"
                )
            }
        }
    }

    @Test("returns an empty result when no manifest exists")
    func emptyRepository() throws {
        let candidates = try SkillsShGitHubContract.discoveryCandidates(
            [tree("Sources")],
            repositoryURL: NormalizedRepositoryURL("https://github.com/owner/repo"),
            repositoryName: "repo"
        )
        #expect(candidates.isEmpty)
    }

    @Test("drops refresh result when catalog changes")
    func staleRefresh() async throws {
        let id = UUID()
        let initial = try record(id: id, revision: 0)
        let changed = try record(id: id, revision: 1)
        let reads = CatalogReads([initial, changed])
        let session = CustomRepositoryDiscoverySession(
            loadCatalog: { _ in await reads.next() },
            discover: { record in discovery(record) }
        )
        await #expect(throws: CustomRepositoryDiscoveryError.staleCatalog) {
            _ = try await session.refresh(repositoryID: id)
        }
    }

    @Test("install snapshot admission rejects modify, disable, and delete")
    func installAdmission() throws {
        let id = UUID()
        let initial = try record(id: id, revision: 0)
        let snapshot = CustomRepositoryInstallSnapshot(
            repositoryID: id,
            databaseRevision: 0,
            repositoryURL: initial.repositoryURL,
            requestedRef: initial.requestedRef,
            commitSHA: String(repeating: "a", count: 40),
            subpath: try RepositorySubpath("skills/demo")
        )
        try snapshot.admit(initial)
        for changed in [try record(id: id, revision: 1), try record(id: id, revision: 0, enabled: false)] {
            #expect(throws: CustomRepositoryDiscoveryError.staleCatalog) {
                try snapshot.admit(changed)
            }
        }
        #expect(throws: CustomRepositoryDiscoveryError.staleCatalog) {
            try snapshot.admit(nil)
        }
    }

    @Test("managed source input checks catalog before refresh and before handoff")
    func managedSourceInputAdmission() async throws {
        let id = UUID()
        let initial = try record(id: id, revision: 0)
        let reads = CatalogReads([initial, try record(id: id, revision: 1)])
        let snapshot = CustomRepositoryInstallSnapshot(
            repositoryID: id,
            databaseRevision: 0,
            repositoryURL: initial.repositoryURL,
            requestedRef: initial.requestedRef,
            commitSHA: String(repeating: "a", count: 40),
            subpath: try RepositorySubpath("skills/demo")
        )
        let input = try snapshot.managedSourceInput(
            displayName: "Demo",
            distributionSlug: DefaultDistributionSlug(validating: "demo"),
            loadCatalog: { _ in await reads.next() },
            refresh: { record in
                CustomRepositoryDiscovery(
                    repositoryID: record.repositoryID,
                    databaseRevision: record.databaseRevision,
                    repositoryURL: record.repositoryURL,
                    requestedRef: record.requestedRef,
                    commitSHA: snapshot.commitSHA,
                    treeSHA: String(repeating: "b", count: 40),
                    candidates: [CustomRepositoryDiscoveryCandidate(
                        subpath: snapshot.subpath,
                        displayName: "demo",
                        providerAlias: try .github(
                            repositoryURL: snapshot.repositoryURL,
                            subpath: snapshot.subpath
                        )
                    )]
                )
            }
        )

        #expect(try await input.refreshHead() == SourceRevision(snapshot.commitSHA))
        await #expect(throws: CustomRepositoryDiscoveryError.staleCatalog) {
            try await input.finalAdmission()
        }
    }

    @Test("custom discovery uses fixed requests and re-reads the default branch")
    func fixedNetworkContract() async throws {
        let requests = CustomRepositoryRequestURLs()
        let commitSHA = String(repeating: "a", count: 40)
        let treeSHA = String(repeating: "b", count: 40)
        let client = SkillsShGitHubSourceClient.live { request, _ in
            let url = try #require(request.url)
            await requests.append(url.absoluteString)
            let body: Data
            if url.path == "/repos/owner/repo" {
                body = Data(
                    #"{"default_branch":"feature/one","full_name":"owner/repo","private":false}"#.utf8
                )
            } else if url.path.contains("/commits/") {
                body = Data(
                    #"{"commit":{"tree":{"sha":"\#(treeSHA)"}},"sha":"\#(commitSHA)"}"#.utf8
                )
            } else {
                body = try JSONSerialization.data(withJSONObject: [
                    "sha": treeSHA,
                    "tree": [[
                        "path": "skills/demo/SKILL.md", "mode": "100644",
                        "type": "blob", "sha": String(repeating: "c", count: 40), "size": 1,
                    ]],
                    "truncated": false,
                ])
            }
            return (body, try customRepositoryResponse(url))
        }
        let catalog = try record(id: UUID(), revision: 0)

        _ = try await client.discoverRepository(catalog)
        _ = try await client.discoverRepository(catalog)
        _ = try await client.discoverRepository(try record(
            id: catalog.repositoryID,
            revision: 1,
            requestedRef: try .explicit(validating: "release/x")
        ))

        let values = await requests.values
        #expect(values.count == 9)
        #expect(values[1] == "https://api.github.com/repos/owner/repo/commits/feature%2Fone")
        #expect(values[4] == values[1])
        #expect(values[7] == "https://api.github.com/repos/owner/repo/commits/release%2Fx")
    }

    @Test("custom discovery preserves typed transport failures and cancellation")
    func typedFailures() async throws {
        let catalog = try record(id: UUID(), revision: 0)
        let timeout = SkillsShGitHubSourceClient.live { _, _ in throw URLError(.timedOut) }
        await #expect(throws: SkillsShGitHubSourceError.timeout) {
            _ = try await timeout.discoverRepository(catalog)
        }

        let cancelled = Task {
            try await SkillsShGitHubSourceClient.live { _, _ in
                try await Task.sleep(for: .milliseconds(20))
                throw URLError(.badServerResponse)
            }.discoverRepository(catalog)
        }
        cancelled.cancel()
        await #expect(throws: SkillsShGitHubSourceError.cancelled) {
            _ = try await cancelled.value
        }
    }

    private func entry(_ path: String) -> SkillsShGitHubContract.TreeEntry {
        SkillsShGitHubContract.TreeEntry(
            path: path,
            components: path.split(separator: "/").map(String.init),
            mode: "100644",
            type: "blob",
            sha: String(repeating: "b", count: 40),
            size: 1
        )
    }


    private func tree(_ path: String) -> SkillsShGitHubContract.TreeEntry {
        SkillsShGitHubContract.TreeEntry(
            path: path,
            components: path.split(separator: "/").map(String.init),
            mode: "040000",
            type: "tree",
            sha: String(repeating: "b", count: 40),
            size: nil
        )
    }

    private func record(
        id: UUID,
        revision: Int64,
        enabled: Bool = true,
        requestedRef: CustomRepositoryRef = .defaultBranch
    ) throws -> CustomRepositoryCatalogRecord {
        CustomRepositoryCatalogRecord(
            repositoryID: id,
            repositoryURL: try NormalizedRepositoryURL("https://github.com/owner/repo"),
            requestedRef: requestedRef,
            displayName: "owner/repo",
            enabled: enabled,
            createdAtMilliseconds: 0,
            updatedAtMilliseconds: revision,
            databaseRevision: revision
        )
    }
}

private actor CustomRepositoryRequestURLs {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private func customRepositoryResponse(_ url: URL) throws -> HTTPURLResponse {
    try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
}

private actor CatalogReads {
    private var records: [CustomRepositoryCatalogRecord]
    init(_ records: [CustomRepositoryCatalogRecord]) { self.records = records }
    func next() -> CustomRepositoryCatalogRecord? {
        records.isEmpty ? nil : records.removeFirst()
    }
}

private func discovery(
    _ record: CustomRepositoryCatalogRecord
) -> CustomRepositoryDiscovery {
    CustomRepositoryDiscovery(
        repositoryID: record.repositoryID,
        databaseRevision: record.databaseRevision,
        repositoryURL: record.repositoryURL,
        requestedRef: record.requestedRef,
        commitSHA: String(repeating: "a", count: 40),
        treeSHA: String(repeating: "b", count: 40),
        candidates: []
    )
}
