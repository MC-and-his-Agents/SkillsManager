import SwiftUI
import UniformTypeIdentifiers

struct HarnessSkillRootSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let store: HarnessSkillRootConfigurationStore
    @State private var resolutions: [SkillPlatform: HarnessSkillRootResolution] = [:]
    @State private var pendingURLs: [SkillPlatform: URL] = [:]
    @State private var pickerPlatform: SkillPlatform?
    @State private var errorMessage: String?

    init(store: HarnessSkillRootConfigurationStore = .shared) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Harness Skill Roots", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.title.bold())
            Text("Choose the directory each harness actually uses. Environment values are hints until you confirm them.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)
            Form {
                ForEach(SkillPlatform.allCases) { platform in
                    rootRow(platform)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: SkillsManagerLocalizationResources.bundle)
                }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .onAppear(perform: reload)
        .fileImporter(
            isPresented: Binding(
                get: { pickerPlatform != nil },
                set: { if !$0 { pickerPlatform = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard let platform = pickerPlatform else { return }
            pickerPlatform = nil
            switch result {
            case .success(let urls):
                if let url = urls.first { pendingURLs[platform] = url.standardizedFileURL }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func rootRow(_ platform: SkillPlatform) -> some View {
        let resolution = resolutions[platform]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(platform.rawValue).font(.headline)
                Spacer()
                Text(resolution?.status.rawValue ?? "unknown")
                    .font(.caption)
                    .foregroundStyle(resolution?.isUsable == true ? Color.secondary : Color.orange)
            }
            if let pending = pendingURLs[platform] {
                Text("Current: \(resolution?.registeredURL.path ?? "—")", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("New: \(pending.path)", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.caption)
                    .textSelection(.enabled)
            } else {
                Text(verbatim: resolution?.registeredURL.path ?? "—")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if let canonical = resolution?.canonicalURL,
               canonical.path != resolution?.registeredURL.path {
                Text("Resolved: \(canonical.path)", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let diagnostic = resolution?.diagnostic {
                Text(diagnostic).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    pickerPlatform = platform
                } label: {
                    Text("Choose…", bundle: SkillsManagerLocalizationResources.bundle)
                }
                if pendingURLs[platform] != nil || resolution?.status == .environmentHint {
                    Button {
                        confirm(platform)
                    } label: {
                        Text("Confirm", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                        .buttonStyle(.borderedProminent)
                }
                if resolution?.isConfigured == true {
                    Button {
                        store.remove(platform: platform)
                        pendingURLs[platform] = nil
                        reload()
                    } label: {
                        Text("Reset", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        resolutions = Dictionary(uniqueKeysWithValues: SkillPlatform.allCases.map { platform in
            (
                platform,
                store.resolution(for: platform)
            )
        })
        errorMessage = nil
    }

    private func confirm(_ platform: SkillPlatform) {
        guard let url = pendingURLs[platform] ?? resolutions[platform]?.registeredURL else {
            return
        }
        do {
            _ = try store.confirm(platform: platform, registeredURL: url)
            pendingURLs[platform] = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
