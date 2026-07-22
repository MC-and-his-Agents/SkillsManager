import Testing
@testable import SkillsManager

@Suite("Repository URL identity")
struct RepositoryIdentityTests {
    @Test("normalizes all supported GitHub transports")
    func githubTransports() throws {
        let expected = "https://github.com/owner/repo"
        for value in [
            "https://github.com/Owner/Repo.git",
            "ssh://git@github.com/Owner/Repo.git",
            "git@github.com:Owner/Repo.git",
            "git@GitHub.com:Owner/Repo.git",
        ] {
            #expect(try NormalizedRepositoryURL(value).value == expected)
        }
    }

    @Test("GitHub grammar fails closed without generic fallback")
    func strictGitHubGrammar() {
        for value in [
            "https://github.com./owner/repo",
            "https://github.com/owner/repo/",
            "https://github.com/owner/repo/tree/main",
            "https://github.com:443/owner/repo",
            "https://github.com:/owner/repo",
            "https://user@github.com/owner/repo",
            "https://github.com/owner/repo?token=secret",
            "https://github.com/owner/repo#fragment",
            "https://github.com/%6fwner/repo",
            "ssh://other@github.com/owner/repo",
            "ssh://%67it@github.com/owner/repo",
            "ssh://git@github.com:/owner/repo",
            "GIT@github.com:owner/repo",
            "https://github.com/owner/repo.GIT",
            "https://github.com/owner/repo.git.git",
        ] {
            #expect(throws: RepositoryIdentityError.self) {
                try NormalizedRepositoryURL(value)
            }
        }
    }

    @Test("normalizes generic HTTPS URLs in a fixed order")
    func genericHTTPS() throws {
        let normalized = try NormalizedRepositoryURL(
            "https://EXAMPLE.com:443/a/%7e/b/../repo.git///"
        )
        #expect(normalized.value == "https://example.com/a/~/repo")
        #expect(try NormalizedRepositoryURL(normalized.value).value == normalized.value)
        #expect(try NormalizedRepositoryURL(
            "https://example.com/a/%2f/b"
        ).value == "https://example.com/a/%2F/b")
        #expect(try NormalizedRepositoryURL(
            "https://bücher.example/a"
        ).value == "https://xn--bcher-kva.example/a")
    }

    @Test("rejects ambiguous or secret-bearing generic URLs")
    func rejectsGenericAmbiguity() {
        for value in [
            "http://example.com/repo",
            "https://example.com./repo",
            "https://example.com:/repo",
            "https://user@example.com/repo",
            "https://example.com/repo?token=secret",
            "https://example.com/repo#fragment",
            "https://example.com/repo.git.git",
        ] {
            #expect(throws: RepositoryIdentityError.self) {
                try NormalizedRepositoryURL(value)
            }
        }
    }

    @Test("enforces normalized repository URL byte boundaries")
    func URLByteBoundaries() throws {
        let prefix = "https://example.com/"
        let values = [
            (length: 2_048, accepted: true),
            (length: 2_049, accepted: false),
        ]
        for value in values {
            let raw = prefix + String(repeating: "a", count: value.length - prefix.utf8.count)
            if value.accepted {
                #expect(try NormalizedRepositoryURL(raw).value.utf8.count == value.length)
            } else {
                #expect(throws: RepositoryIdentityError.URLTooLong) {
                    try NormalizedRepositoryURL(raw)
                }
            }
        }
    }

    @Test("source records retain typed schema identities")
    func sourceRecord() throws {
        let skillID = SkillID()
        let sourceID = SourceID()
        let source = SkillSourceRecord(
            sourceID: sourceID,
            skillID: skillID,
            repositoryURL: try NormalizedRepositoryURL("https://github.com/owner/repo"),
            subpath: try RepositorySubpath("skills/example"),
            revision: try SourceRevision("main"),
            version: try SourceVersion("1.0.0"),
            downloadURL: try PublicDownloadURL("https://example.com/skill.zip")
        )

        #expect(source.sourceID == sourceID)
        #expect(source.skillID == skillID)
        #expect(source.repositoryURL.value == "https://github.com/owner/repo")
        #expect(source.subpath.value == "skills/example")
        #expect(source.revision?.value == "main")
        #expect(source.version?.value == "1.0.0")
        #expect(source.downloadURL?.value == "https://example.com/skill.zip")
    }
}
