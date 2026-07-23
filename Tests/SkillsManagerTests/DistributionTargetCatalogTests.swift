import Foundation
import Testing
@testable import SkillsManager

@Suite("Distribution target catalog")
struct DistributionTargetCatalogTests {
    private let catalog = DistributionTargetCatalog.current

    @Test("freezes adapter codes, global readers, and dedicated targets")
    func frozenMatrix() {
        #expect(SkillPlatform.allCases.map(\.storageKey) == [
            "codex", "claude", "opencode", "copilot",
        ])
        #expect(catalog.globalReaders == [.codex, .opencode, .copilot])
        #expect(catalog.globalTarget.rootLocator == "~/.agents/skills")
        #expect(catalog.target(for: .agent(.codex))?.rootLocator == "~/.codex/skills")
        #expect(catalog.target(for: .agent(.claude))?.rootLocator == "~/.claude/skills")
        #expect(
            catalog.target(for: .agent(.opencode))?.rootLocator
                == "~/.config/opencode/skills"
        )
        #expect(catalog.target(for: .agent(.copilot))?.rootLocator == "~/.copilot/skills")
    }

    @Test("keeps discovery compatibility paths out of distribution targets")
    func discoveryOnlyPaths() throws {
        let slug = try DefaultDistributionSlug(validating: "review")
        let codexEntry = try #require(catalog.entry(for: .agent(.codex), slug: slug))
        let openCodeEntry = try #require(catalog.entry(for: .agent(.opencode), slug: slug))

        #expect(SkillPlatform.codex.discoveryCompatibilityRelativePaths == [
            ".codex/skills/public",
        ])
        #expect(SkillPlatform.opencode.discoveryCompatibilityRelativePaths == [
            ".claude/skills",
        ])
        #expect(codexEntry.canonicalLocator == "~/.codex/skills/review")
        #expect(!codexEntry.canonicalLocator.contains("/public/"))
        #expect(openCodeEntry.canonicalLocator == "~/.config/opencode/skills/review")
        #expect(!openCodeEntry.canonicalLocator.contains("/opencode/skill/"))
    }

    @Test("uses fixed Codex and SSOT locators")
    func fixedLocators() throws {
        let skillID = SkillID(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
        let slug = try DefaultDistributionSlug(validating: "Café")

        #expect(catalog.entry(for: .agent(.codex), slug: slug)?.canonicalLocator
            == "~/.codex/skills/Café")
        #expect(catalog.ssotLocator(for: skillID)
            == "~/.SkillsManager/skills/00112233-4455-6677-8899-aabbccddeeff")
    }

    @Test("computes typed scope keys and validates Binding timestamps")
    func bindingDomain() throws {
        let skillID = SkillID(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
        let slug = try DefaultDistributionSlug(validating: "Review")
        let binding = try DistributionBinding(
            skillID: skillID,
            scope: .agent(.opencode),
            distributionSlug: slug,
            createdAtMilliseconds: 10,
            updatedAtMilliseconds: 11
        )

        #expect(DistributionBindingScope.global.targetScopeKey == "global")
        #expect(binding.scope.targetScopeKey == "agent:opencode")
        #expect(binding.syncMode == .symlink)
        #expect(binding.distributionSlug.collisionKey == SkillContentPath.collisionKey(for: "Review"))
        #expect(throws: DistributionBindingError.invalidTimestampRange) {
            try DistributionBinding(
                skillID: skillID,
                scope: .global,
                distributionSlug: slug,
                createdAtMilliseconds: 2,
                updatedAtMilliseconds: 1
            )
        }
    }
}
