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

    @Test("an old timer cannot dismiss a newer result")
    func staleTimerCannotDismissCurrentResult() async throws {
        let center = SkillResultCenter(autoDismissDelay: .milliseconds(200))
        let first = entry(text: "First")
        let second = entry(text: "Second")

        center.publish(first)
        try await Task.sleep(for: .milliseconds(50))
        center.publish(second)
        try await Task.sleep(for: .milliseconds(170))

        #expect(center.visible?.id == second.id)
    }

    @Test("manual dismissal only affects the matching result")
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

        center.publishInstallResult(result, skillID: "remote-id")
        #expect(center.visible?.skillID == "remote-id")
        #expect(center.visible?.systemImage == "checkmark.seal")

        center.publishInstallFailure("Failed", skillID: "remote-id")
        #expect(center.visible?.text == "Failed")
        #expect(center.visible?.systemImage == "exclamationmark.triangle.fill")
    }

    private func entry(text: String) -> SkillResultCenter.Entry {
        SkillResultCenter.Entry(
            skillID: "skill-id",
            text: text,
            systemImage: "checkmark.circle",
            tint: .green
        )
    }
}
