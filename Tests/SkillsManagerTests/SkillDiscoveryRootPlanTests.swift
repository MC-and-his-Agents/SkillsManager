import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill discovery root plan")
struct SkillDiscoveryRootPlanTests {
    @Test("plan inherits existing adapters and adds the global root")
    func includesExpectedRoots() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let custom = CustomSkillPath(
            id: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
            url: URL(fileURLWithPath: "/Projects/demo", isDirectory: true),
            displayName: "Demo",
            addedAt: Date(timeIntervalSince1970: 0)
        )

        let roots = SkillDiscoveryRootPlan.make(homeURL: home, customPaths: [custom])

        #expect(roots.count == 12)
        #expect(roots[0] == SkillDiscoveryRoot(
            scope: .global,
            url: home.appendingPathComponent(".agents/skills", isDirectory: true)
        ))
        let homePaths = Set(roots.filter { $0.scope.kind == .agent }.map(\.url.path))
        #expect(homePaths == Set([
            "/Users/example/.codex/skills",
            "/Users/example/.codex/skills/public",
            "/Users/example/.claude/skills",
            "/Users/example/.config/opencode/skill",
            "/Users/example/.copilot/skills",
        ]))
        let customRoots = roots.filter { $0.scope.kind == .custom }
        #expect(customRoots.count == 5)
        #expect(customRoots.allSatisfy { $0.scope.customPathID == custom.id })
        #expect(Set(customRoots.map(\.url.path)) == Set([
            "/Projects/demo/.codex/skills",
            "/Projects/demo/.codex/skills/public",
            "/Projects/demo/.claude/skills",
            "/Projects/demo/.config/opencode/skill",
            "/Projects/demo/.copilot/skills",
        ]))
    }

    @Test("direct collection roots scan the selected directory without nesting")
    func directCollectionRoot() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let collection = URL(fileURLWithPath: "/Volumes/skills/.codex/skills", isDirectory: true)
        let custom = CustomSkillPath(
            id: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
            url: collection,
            displayName: "Codex",
            addedAt: Date(timeIntervalSince1970: 0),
            mode: .collection(adapter: .codex)
        )

        let roots = SkillDiscoveryRootPlan.make(homeURL: home, customPaths: [custom])
        let customRoots = roots.filter { $0.scope.customPathID == custom.id }

        #expect(customRoots.count == 1)
        #expect(customRoots.first?.url.path == collection.path)
        #expect(customRoots.first?.scope.adapterCode == "codex")
        #expect(customRoots.first?.scope.pathVariant == CustomSkillPathMode.directPathVariant)
        #expect(!customRoots.contains {
            $0.url.path.hasSuffix("/.codex/skills/.codex/skills")
        })
    }

    @Test("standard path suffix suggestions require an explicit adapter when ambiguous")
    func standardSuffixSuggestions() {
        #expect(
            CustomSkillPathMode.suggestedAdapters(
                for: URL(fileURLWithPath: "/tmp/.codex/skills", isDirectory: true)
            ) == [.codex]
        )
        #expect(
            CustomSkillPathMode.suggestedAdapters(
                for: URL(fileURLWithPath: "/tmp/.claude/skills", isDirectory: true)
            ) == [.claude, .opencode]
        )
    }
}
