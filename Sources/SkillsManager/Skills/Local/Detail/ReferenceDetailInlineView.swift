import MarkdownUI
import SwiftUI

struct ReferenceDetailInlineView: View {
    @Environment(SkillStore.self) private var store

    var body: some View {
        switch store.referenceState {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView(String(localized: "Loading reference…", bundle: SkillsManagerLocalizationResources.bundle))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .missing:
            ContentUnavailableView(String(localized: "Missing reference", bundle: SkillsManagerLocalizationResources.bundle),
                                   systemImage: "doc",
                                   description: Text("This reference file could not be found.", bundle: SkillsManagerLocalizationResources.bundle))
        case .failed(let message):
            ContentUnavailableView(String(localized: "Unable to load reference", bundle: SkillsManagerLocalizationResources.bundle),
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(verbatim: message))
        case .loaded:
            Markdown(store.selectedReferenceMarkdown)
                .textSelection(.enabled)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )
        }
    }
}
