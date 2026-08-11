import SwiftUI
import Testing
@testable import SkillsManager

@Suite("Skill result center")
@MainActor
struct SkillResultCenterTests {
    @Test("repeated text creates a new visible result")
    func repeatedTextIsNewResult() {
        let center = SkillResultCenter()
        let first = entry(text: "Done")
        let second = entry(text: "Done")

        center.publish(first)
        center.publish(second)

        #expect(first.id != second.id)
        #expect(center.visible?.id == second.id)
    }

    @Test("stale timer or manual dismissal only affects the matching result")
    func dismissalIsIdentityGated() {
        let center = SkillResultCenter()
        let first = entry(text: "First")
        let second = entry(text: "Second")

        center.publish(first)
        center.publish(second)
        center.dismiss(entryID: first.id)
        #expect(center.visible?.id == second.id)

        center.dismiss(entryID: second.id)
        #expect(center.visible == nil)
    }

    @Test("install success and failure publish to the requested detail")
    func installOutcomesUseRequestedSubject() {
        let center = SkillResultCenter()
        let result = ManagedLocalImportResult(
            skillID: SkillID(),
            displayName: "Demo",
            status: .distributed
        )

        center.publishInstallResult(result, subject: .clawHub("remote-id"))
        #expect(center.visible?.subject == .clawHub("remote-id"))
        #expect(center.visible?.systemImage == "checkmark.seal")

        center.publishInstallFailure("Failed", subject: .clawHub("remote-id"))
        #expect(center.visible?.text == "Failed")
        #expect(center.visible?.systemImage == "exclamationmark.triangle.fill")
    }

    @Test("provider namespaces and complete skills.sh identities do not collide")
    func subjectsDoNotCollide() {
        let first = SkillsShSearchResultID(searchItem(source: "one"))
        let second = SkillsShSearchResultID(searchItem(source: "two"))

        #expect(SkillResultCenter.Subject.managed("same") != .clawHub("same"))
        #expect(SkillResultCenter.Subject.skillsSh(first) != .skillsSh(second))
    }

    private func entry(text: String) -> SkillResultCenter.Entry {
        SkillResultCenter.Entry(
            subject: .managed("skill-id"),
            text: text,
            systemImage: "checkmark.circle",
            tint: .green
        )
    }

    private func searchItem(source: String) -> SkillsShSearchItem {
        SkillsShSearchItem(
            id: "same",
            skillID: "skill",
            name: "Demo",
            installs: 0,
            source: source
        )
    }
}
