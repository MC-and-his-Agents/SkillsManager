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

        #expect(roots.count == 11)
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
    }
}
