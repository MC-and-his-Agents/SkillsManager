import AppKit
import SwiftUI

struct CustomPathSectionHeader: View {
    @Environment(SkillStore.self) private var store
    let customPath: CustomSkillPath

    @State private var showingRemoveAlert = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(customPath.displayName)
                Text(customPath.url.path)
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
        .alert("Remove Custom Path?", isPresented: $showingRemoveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                store.removeCustomPath(customPath)
                Task { await store.loadSkills() }
            }
        } message: {
            Text("This will remove \"\(customPath.displayName)\" from the sidebar. The skills will not be deleted from disk.")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button {
            NSWorkspace.shared.open(customPath.url)
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            showingRemoveAlert = true
        } label: {
            Label("Remove Path", systemImage: "trash")
        }
    }
}
