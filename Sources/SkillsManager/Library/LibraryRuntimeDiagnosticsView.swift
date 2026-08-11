import SwiftUI

struct LibraryRuntimeDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryRuntimeState.self) private var runtime

    var body: some View {
        NavigationStack {
            List(runtime.diagnostics, id: \.id) { diagnostic in
                VStack(alignment: .leading, spacing: 5) {
                    Label {
                        Text(verbatim: localizedLibraryDiagnosticCode(diagnostic.code))
                            .font(.headline)
                    } icon: {
                        Image(systemName: diagnostic.blocking
                            ? "lock.trianglebadge.exclamationmark"
                            : "exclamationmark.triangle")
                            .foregroundStyle(diagnostic.blocking ? .red : .orange)
                    }
                    Text(verbatim: diagnostic.userFacingMessage)
                        .font(.callout)
                    Text(
                        String(
                            localized: LocalizedStringResource(
                                "Recommended action: \(localizedRecommendedActionCode(diagnostic.recommendedActionCode))",
                                bundle: SkillsManagerLocalizationResources.bundle
                            )
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .navigationTitle(Text("Library diagnostics", bundle: SkillsManagerLocalizationResources.bundle))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Close", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}
