import Testing

@testable import SkillsManager

@Suite("Installed Skill platform index")
struct InstalledSkillPlatformIndexTests {
    @Test("lookup matches case and Unicode-equivalent provider slugs")
    func normalizedIdentityLookup() {
        let index = InstalledSkillPlatformIndex(entries: [
            (slug: "Remote-Slug", platform: .codex),
            (slug: "cafe\u{301}-skill", platform: .claude),
        ])

        #expect(index.platforms(forSlug: "REMOTE-SLUG") == [.codex])
        #expect(index.platforms(forSlug: "CAFÉ-SKILL") == [.claude])
    }
}
