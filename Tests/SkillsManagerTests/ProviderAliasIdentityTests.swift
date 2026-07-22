import Testing
@testable import SkillsManager

@Suite("Provider alias and source metadata")
struct ProviderAliasIdentityTests {
    @Test("accepts stable provider codes and opaque identifiers")
    func providerAlias() throws {
        let alias = try ProviderAliasIdentity(provider: "skills.sh-v1", identifier: "Owner/Skill 🧰")
        let sourceID = SourceID()
        let record = ProviderAliasRecord(sourceID: sourceID, identity: alias)
        #expect(alias.provider == "skills.sh-v1")
        #expect(alias.identifier == "Owner/Skill 🧰")
        #expect(record.sourceID == sourceID)
        #expect(record.identity == alias)
    }

    @Test("rejects invalid provider fields")
    func invalidProviderAlias() {
        for provider in ["", "Upper", "-leading", "white space", "provider!"] {
            #expect(throws: SourceMetadataError.invalidProvider) {
                try ProviderAliasIdentity(provider: provider, identifier: "id")
            }
        }
        #expect(throws: SourceMetadataError.invalidProviderIdentifier) {
            try ProviderAliasIdentity(provider: "valid", identifier: "")
        }
        #expect(throws: SourceMetadataError.invalidProviderIdentifier) {
            try ProviderAliasIdentity(
                provider: "valid",
                identifier: String(repeating: "a", count: 1_025)
            )
        }
    }

    @Test("enforces Provider and identifier byte boundaries")
    func providerBoundaries() throws {
        for value in [
            (length: 64, accepted: true),
            (length: 65, accepted: false),
        ] {
            let provider = "p" + String(repeating: "a", count: value.length - 1)
            if value.accepted {
                #expect(try ProviderAliasIdentity(provider: provider, identifier: "id").provider == provider)
            } else {
                #expect(throws: SourceMetadataError.invalidProvider) {
                    try ProviderAliasIdentity(provider: provider, identifier: "id")
                }
            }
        }

        for value in [
            (length: 1_024, accepted: true),
            (length: 1_025, accepted: false),
        ] {
            let identifier = String(repeating: "a", count: value.length)
            if value.accepted {
                #expect(try ProviderAliasIdentity(
                    provider: "valid",
                    identifier: identifier
                ).identifier.utf8.count == value.length)
            } else {
                #expect(throws: SourceMetadataError.invalidProviderIdentifier) {
                    try ProviderAliasIdentity(provider: "valid", identifier: identifier)
                }
            }
        }
    }

    @Test("validates revision and version bounds")
    func revisionAndVersion() throws {
        #expect(try SourceRevision("main").value == "main")
        #expect(try SourceVersion("1.0.0").value == "1.0.0")
        #expect(throws: SourceMetadataError.invalidRevision) { try SourceRevision("") }
        #expect(throws: SourceMetadataError.invalidVersion) { try SourceVersion("") }

        for value in [
            (length: 512, accepted: true),
            (length: 513, accepted: false),
        ] {
            let raw = String(repeating: "a", count: value.length)
            if value.accepted {
                #expect(try SourceRevision(raw).value.utf8.count == value.length)
                #expect(try SourceVersion(raw).value.utf8.count == value.length)
            } else {
                #expect(throws: SourceMetadataError.invalidRevision) { try SourceRevision(raw) }
                #expect(throws: SourceMetadataError.invalidVersion) { try SourceVersion(raw) }
            }
        }
    }

    @Test("persists only public HTTPS download URLs")
    func publicDownloadURL() throws {
        #expect(try PublicDownloadURL(
            "https://EXAMPLE.com:443/releases/skill.zip"
        ).value == "https://example.com/releases/skill.zip")
        for value in [
            "http://example.com/skill.zip",
            "https://example.com./skill.zip",
            "https://user@example.com/skill.zip",
            "https://example.com/skill.zip?signature=secret",
            "https://example.com/skill.zip#fragment",
        ] {
            #expect(throws: SourceMetadataError.invalidDownloadURL) {
                try PublicDownloadURL(value)
            }
        }

        let prefix = "https://example.com/"
        for value in [
            (length: 2_048, accepted: true),
            (length: 2_049, accepted: false),
        ] {
            let raw = prefix + String(repeating: "a", count: value.length - prefix.utf8.count)
            if value.accepted {
                #expect(try PublicDownloadURL(raw).value.utf8.count == value.length)
            } else {
                #expect(throws: SourceMetadataError.invalidDownloadURL) {
                    try PublicDownloadURL(raw)
                }
            }
        }
    }
}
