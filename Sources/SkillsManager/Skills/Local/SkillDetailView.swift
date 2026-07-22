import SwiftUI

struct SkillDetailView: View {
    @Environment(SkillStore.self) private var store

    var body: some View {
        if let skill = store.selectedSkill {
            content(for: skill)
        } else {
            ContentUnavailableView("Select a skill",
                                   systemImage: "sparkles",
                                   description: Text("Pick a skill from the list."))
        }
    }

    @ViewBuilder
    private func content(for skill: Skill) -> some View {
        switch store.detailState {
        case .idle, .loading:
            ProgressView("Loading \(skill.name)...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView("Missing SKILL.md",
                                   systemImage: "doc",
                                   description: Text("No SKILL.md found in this skill folder."))
        case .failed(let message):
            ContentUnavailableView("Unable to load",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded:
            SkillMarkdownView(skill: skill, markdown: store.selectedMarkdown)
        }
    }
}
