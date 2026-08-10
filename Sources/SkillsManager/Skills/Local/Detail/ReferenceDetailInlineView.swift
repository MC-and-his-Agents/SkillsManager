import MarkdownUI
import SwiftUI

struct ReferenceDetailInlineView: View {
    @Environment(SkillStore.self) private var store

    var body: some View {
        switch store.referenceState {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView(String(localized: "Loading reference…", bundle: .module))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .missing:
            ContentUnavailableView(String(localized: "Missing reference", bundle: .module),
                                   systemImage: "doc",
                                   description: Text("This reference file could not be found.", bundle: .module))
        case .failed(let message):
            ContentUnavailableView(String(localized: "Unable to load reference", bundle: .module),
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(message))
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
