import Testing
@testable import SkillsManager

@Suite("Repository subpath identity")
struct RepositorySubpathTests {
    @Test("normalizes decoded relative tree paths")
    func normalization() throws {
        #expect(try RepositorySubpath("").value == "")
        #expect(try RepositorySubpath("skills/./Cafe\u{301}").value == "skills/Caf\u{e9}")
        let normalized = try RepositorySubpath("skills/./tool")
        #expect(try RepositorySubpath(normalized.value) == normalized)
    }

    @Test("rejects ambiguous and encoded paths")
    func rejection() {
        for value in ["/skills", "skills/", "a//b", "a/../b", "a\\b", "a%2Fb", "a\0b"] {
            #expect(throws: RepositorySubpathError.self) {
                try RepositorySubpath(value)
            }
        }
    }

    @Test("enforces normalized byte limit")
    func byteLimit() throws {
        let values = [
            (length: 1_024, accepted: true),
            (length: 1_025, accepted: false),
        ]
        for value in values {
            let raw = String(repeating: "a", count: value.length)
            if value.accepted {
                #expect(try RepositorySubpath(raw).value.utf8.count == value.length)
            } else {
                #expect(throws: RepositorySubpathError.pathTooLong) {
                    try RepositorySubpath(raw)
                }
            }
        }
    }
}
