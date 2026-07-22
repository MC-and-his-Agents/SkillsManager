import Foundation
import Testing
@testable import SkillsManager

@Suite("Default distribution slug")
struct DefaultDistributionSlugTests {
    @Test("normalizes display names and maps separator runs")
    func normalizationAndMapping() throws {
        let displayName = try SkillDisplayName("  Cafe\u{301}:\n\\Tools//--  ")
        let slug = try DefaultDistributionSlug(candidateFrom: displayName)

        #expect(displayName.value == "  Caf\u{e9}:\n\\Tools//--  ")
        #expect(slug.value == "Caf\u{e9}-Tools")
    }

    @Test("preserves emoji and falls back after an empty result")
    func emojiAndFallback() throws {
        #expect(try DefaultDistributionSlug(
            candidateFrom: SkillDisplayName("Build 🧰 Skill")
        ).value == "Build-🧰-Skill")
        #expect(try DefaultDistributionSlug(
            candidateFrom: SkillDisplayName(" .--:\n ")
        ).value == "skill")
    }

    @Test("truncates only at complete extended grapheme boundaries")
    func completeGraphemeTruncation() throws {
        let boundary = String(repeating: "a", count: 199) + "é"
        #expect(try DefaultDistributionSlug(
            candidateFrom: SkillDisplayName(boundary)
        ).value == String(repeating: "a", count: 199))

        let oversizedGrapheme = "a" + String(repeating: "\u{301}", count: 210)
        #expect(oversizedGrapheme.count == 1)
        #expect(try DefaultDistributionSlug(
            candidateFrom: SkillDisplayName(oversizedGrapheme + "tail")
        ).value == "skill")
    }

    @Test("trims a trailing dot exposed by truncation")
    func trimsAfterTruncation() throws {
        let value = String(repeating: "a", count: 199) + ".b"
        #expect(try DefaultDistributionSlug(
            candidateFrom: SkillDisplayName(value)
        ).value == String(repeating: "a", count: 199))
    }

    @Test("validates persisted slugs and collision keys")
    func validation() throws {
        let composed = try DefaultDistributionSlug(validating: "Café")
        let decomposed = try DefaultDistributionSlug(validating: "CAFE\u{301}")
        #expect(composed.collisionKey == decomposed.collisionKey)

        for invalid in ["", ".hidden", "a/b", "a\\b", "a\0b"] {
            #expect(throws: SkillPresentationError.self) {
                try DefaultDistributionSlug(validating: invalid)
            }
        }
        #expect(throws: SkillPresentationError.invalidDistributionSlug) {
            try DefaultDistributionSlug(validating: String(repeating: "a", count: 201))
        }
    }

    @Test("enforces display-name byte limits")
    func displayNameLimits() throws {
        let values = [
            (length: 0, accepted: false),
            (length: 512, accepted: true),
            (length: 513, accepted: false),
        ]
        for value in values {
            let raw = String(repeating: "a", count: value.length)
            if value.accepted {
                #expect(try SkillDisplayName(raw).value.utf8.count == value.length)
            } else {
                #expect(throws: SkillPresentationError.invalidDisplayName) {
                    try SkillDisplayName(raw)
                }
            }
        }
    }

    @Test("enforces persisted slug byte boundaries")
    func slugLimits() throws {
        let values = [
            (length: 200, accepted: true),
            (length: 201, accepted: false),
        ]
        for value in values {
            let raw = String(repeating: "a", count: value.length)
            if value.accepted {
                #expect(try DefaultDistributionSlug(validating: raw).value.utf8.count == value.length)
            } else {
                #expect(throws: SkillPresentationError.invalidDistributionSlug) {
                    try DefaultDistributionSlug(validating: raw)
                }
            }
        }
    }
}
