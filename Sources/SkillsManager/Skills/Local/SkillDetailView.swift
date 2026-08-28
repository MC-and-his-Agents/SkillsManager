import SwiftUI

struct SkillDetailView: View {
    @Environment(SkillStore.self) private var store

    var body: some View {
        if let skill = store.selectedSkill {
            content(for: skill)
        } else {
            ContentUnavailableView(String(localized: "Select a skill", bundle: SkillsManagerLocalizationResources.bundle),
                                   systemImage: "sparkles",
                                   description: Text("Pick a skill from the list.", bundle: SkillsManagerLocalizationResources.bundle))
        }
    }

    @ViewBuilder
    private func content(for skill: Skill) -> some View {
        switch store.detailState {
        case .idle, .loading:
            HStack {
                ProgressView()
                Text("Loading \(skill.name)", bundle: SkillsManagerLocalizationResources.bundle)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView(String(localized: "Missing SKILL.md", bundle: SkillsManagerLocalizationResources.bundle),
                                   systemImage: "doc",
                                   description: Text("No SKILL.md found in this skill folder.", bundle: SkillsManagerLocalizationResources.bundle))
        case .failed(let message):
            ContentUnavailableView(String(localized: "Unable to load", bundle: SkillsManagerLocalizationResources.bundle),
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(verbatim: message))
        case .loaded:
            SkillMarkdownView(skill: skill, markdown: store.selectedMarkdown)
        }
    }
}
