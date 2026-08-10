import SwiftUI

struct SkillDetailView: View {
    @Environment(SkillStore.self) private var store

    var body: some View {
        if let skill = store.selectedSkill {
            content(for: skill)
        } else {
            ContentUnavailableView(String(localized: "Select a skill", bundle: .module),
                                   systemImage: "sparkles",
                                   description: Text("Pick a skill from the list.", bundle: .module))
        }
    }

    @ViewBuilder
    private func content(for skill: Skill) -> some View {
        switch store.detailState {
        case .idle, .loading:
            HStack {
                ProgressView()
                Text("Loading ", bundle: .module)
                Text(skill.name)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView(String(localized: "Missing SKILL.md", bundle: .module),
                                   systemImage: "doc",
                                   description: Text("No SKILL.md found in this skill folder.", bundle: .module))
        case .failed(let message):
            ContentUnavailableView(String(localized: "Unable to load", bundle: .module),
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded:
            SkillMarkdownView(skill: skill, markdown: store.selectedMarkdown)
        }
    }
}
