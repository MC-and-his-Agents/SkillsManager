import AppKit
import SwiftUI

struct CustomPathSectionHeader: View {
    @Environment(SkillStore.self) private var store
    @Environment(LibraryRuntimeState.self) private var libraryRuntime
    let customPath: CustomSkillPath

    @State private var showingRemoveAlert = false
    @State private var operationErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: customPath.displayName)
                    Text(verbatim: customPath.url.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: modeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

            if libraryRuntime.readiness == .blocked {
                Text(verbatim: libraryRuntime.blockingMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if let operationErrorMessage {
                Text(verbatim: operationErrorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
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
                removePath()
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

    private func removePath() {
        guard libraryRuntime.readiness == .ready else {
            operationErrorMessage = libraryRuntime.blockingMessage
            return
        }
        Task { @MainActor in
            guard libraryRuntime.readiness == .ready else {
                operationErrorMessage = libraryRuntime.blockingMessage
                return
            }
            do {
                try await store.removeCustomPath(customPath)
                await store.loadSkills()
            } catch {
                operationErrorMessage = error is LibraryPersistenceError
                    || libraryRuntime.readiness == .blocked
                    ? libraryRuntime.blockingMessage
                    : error.localizedDescription
            }
        }
    }

    private var modeLabel: String {
        switch customPath.mode {
        case .project:
            return "Project root"
        case .collection(let adapter):
            return "Direct collection · \(adapter.rawValue)"
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
        .disabled(libraryRuntime.readiness != .ready)
        .help(Text(verbatim: libraryRuntime.blockingMessage))
    }
}
