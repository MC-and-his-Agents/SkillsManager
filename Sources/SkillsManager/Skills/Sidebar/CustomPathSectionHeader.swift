import AppKit
import SwiftUI

struct CustomPathSectionHeader: View {
    @Environment(SkillStore.self) private var store
    let customPath: CustomSkillPath

    @State private var showingRemoveAlert = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: customPath.displayName)
                Text(verbatim: customPath.url.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Menu {
                menuContent
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contextMenu {
            menuContent
        }
        .alert(Text("Remove Custom Path?", bundle: SkillsManagerLocalizationResources.bundle), isPresented: $showingRemoveAlert) {
            Button(role: .cancel) {
            } label: {
                Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
            }
            Button(role: .destructive) {
                Task {
                    try? await store.removeCustomPath(customPath)
                    await store.loadSkills()
                }
            } label: {
                Text("Remove", bundle: SkillsManagerLocalizationResources.bundle)
            }
        } message: {
            Text(String(
                localized: LocalizedStringResource(
            "This will remove \"\(customPath.displayName)\" from the sidebar. The skills will not be deleted from disk.",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button {
            NSWorkspace.shared.open(customPath.url)
        } label: {
            Label {
                Text("Open in Finder", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "folder")
            }
        }
        Divider()
        Button(role: .destructive) {
            showingRemoveAlert = true
        } label: {
            Label {
                Text("Remove Path", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "trash")
            }
        }
    }
}
