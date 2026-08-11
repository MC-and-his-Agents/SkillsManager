import SwiftUI
import UniformTypeIdentifiers

struct AddCustomPathView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @Environment(LibraryRuntimeState.self) private var libraryRuntime

    @State private var showingPicker = false
    @State private var selectedURL: URL?
    @State private var selectedMode: CustomSkillPathMode = .project
    @State private var suggestedAdapters: [SkillPlatform] = []
    @State private var selectedAdapter: SkillPlatform?
    @State private var previewRoots: [SkillDiscoveryRoot] = []
    @State private var errorMessage: String?
    @State private var isValidating = false
    @State private var discoveredSkills: [SkillPlatform: [DiscoveredSkill]] = [:]
    @State private var rootDiagnostics: [SkillDiscoveryRootDiagnostic] = []
    @State private var validSkillCount = 0

    private struct DiscoveredSkill: Identifiable {
        let id: String
        let displayName: String
        let location: String
        let status: SkillDiscoveryStatus
        let reason: SkillDiscoveryReason?
        let isValid: Bool
    }

    private var totalSkillCount: Int {
        discoveredSkills.values.reduce(0) { $0 + $1.count }
    }

    private var sortedPlatforms: [SkillPlatform] {
        SkillPlatform.allCases.filter { discoveredSkills[$0]?.isEmpty == false }
    }

    private var adapterOptions: [SkillPlatform] {
        suggestedAdapters.isEmpty ? SkillPlatform.allCases : suggestedAdapters
    }

    private var selectedModeLabel: String {
        switch selectedMode {
        case .project: "Project root"
        case .collection: "Direct Skill collection root"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            Spacer()
            actions
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handlePick(result)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add Custom Skill Path", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.title.bold())
            Text("Select a project folder or a direct Skill collection root. Project roots use known platform subpaths; collection roots scan direct Skill children.", bundle: SkillsManagerLocalizationResources.bundle)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if libraryRuntime.readiness == .blocked {
            Label {
                Text(verbatim: libraryRuntime.blockingMessage)
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .accessibilityIdentifier("library.runtime-blocked")
        }

        if isValidating {
            HStack {
                ProgressView()
                Text("Scanning for skills...", bundle: SkillsManagerLocalizationResources.bundle)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = selectedURL {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderPreview(url: url)
                    modePicker
                    scanRootsView
                    Text(String(
                        localized: LocalizedStringResource(
                            "(validSkillCount) valid · (totalSkillCount) observed candidate(s)",
                            bundle: SkillsManagerLocalizationResources.bundle
                        )
                    ))
                    .font(.subheadline)
                    .foregroundStyle(validSkillCount > 0 ? .green : .secondary)
                    if !discoveredSkills.isEmpty {
                        discoveredSkillsView
                    }
                    if !rootDiagnostics.isEmpty {
                        diagnosticsView
                    }
                }
            }
        } else {
            ContentUnavailableView(
                String(localized: "Select a project folder", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "folder.badge.plus",
                description: Text("Choose a folder containing platform skill directories", bundle: SkillsManagerLocalizationResources.bundle)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        if let error = errorMessage {
            Text(verbatim: error)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func folderPreview(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(verbatim: url.lastPathComponent)
                    .font(.headline)
            }
                Text(verbatim: url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(verbatim: selectedModeLabel)
                    .font(.caption)
                if let selectedAdapter {
                    TagView(localized: platformResource(selectedAdapter), tint: selectedAdapter.badgeTint)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.1)))
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Path type", selection: Binding(
                get: {
                    if case .project = selectedMode { return "project" }
                    return "collection"
                },
                set: { value in
                    if value == "project" {
                        selectedMode = .project
                        selectedAdapter = nil
                    } else {
                        if selectedAdapter == nil, suggestedAdapters.count == 1 {
                            selectedAdapter = suggestedAdapters[0]
                        }
                        selectedMode = .collection(adapter: selectedAdapter ?? suggestedAdapters.first ?? .codex)
                    }
                    rescanSelectedURL()
                }
            )) {
                Text("Project root", bundle: SkillsManagerLocalizationResources.bundle).tag("project")
                Text("Direct Skill collection root", bundle: SkillsManagerLocalizationResources.bundle).tag("collection")
            }
            .pickerStyle(.segmented)

            if case .collection = selectedMode {
                Picker("Adapter", selection: Binding<SkillPlatform?>(
                    get: { selectedAdapter },
                    set: {
                        selectedAdapter = $0
                        if let adapter = $0 {
                            selectedMode = .collection(adapter: adapter)
                        }
                        rescanSelectedURL()
                    }
                )) {
                    Text("Choose an adapter", bundle: SkillsManagerLocalizationResources.bundle)
                        .tag(nil as SkillPlatform?)
                    ForEach(adapterOptions) { platform in
                        Text(platformResource(platform)).tag(Optional(platform))
                    }
                }
                .labelsHidden()
                if suggestedAdapters.count > 1 && selectedAdapter == nil {
                    Text("This standard path matches more than one adapter; choose one explicitly.", bundle: SkillsManagerLocalizationResources.bundle)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var scanRootsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Actual scan roots", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.headline)
            if previewRoots.isEmpty {
                Text("No scan roots", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(previewRoots, id: \.self) { root in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: root.url.standardizedFileURL.path)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var discoveredSkillsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Discovered Skills", bundle: SkillsManagerLocalizationResources.bundle)
                    .font(.headline)
                Spacer()
                Text(String(
                    localized: LocalizedStringResource(
            "\(validSkillCount) valid · \(totalSkillCount) observed",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .font(.subheadline)
                    .foregroundStyle(validSkillCount > 0 ? .green : .secondary)
            }

            Text("Skills stay in place; this path is registered for read-only discovery.", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(sortedPlatforms, id: \.self) { platform in
                if let skills = discoveredSkills[platform], !skills.isEmpty {
                    platformSkillsSection(platform: platform, skills: skills)
                }
            }
        }
    }

    private func platformSkillsSection(platform: SkillPlatform, skills: [DiscoveredSkill]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TagView(localized: platformResource(platform), tint: platform.badgeTint)
                Text(String(
                    localized: LocalizedStringResource(
            "\(skills.count) skill(s)",
            bundle: SkillsManagerLocalizationResources.bundle
        )))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: platform.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(skills) { skill in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: skill.status.systemImage)
                            .font(.caption)
                            .foregroundStyle(skill.status.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: skill.displayName)
                                .font(.callout)
                            Text(verbatim: skill.location)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let reason = skill.reason {
                                Text(verbatim: reason.localizedDisplayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if !skill.isValid {
                                Text(verbatim: skill.status.localizedDisplayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.leading, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue([
                        skill.status.localizedDisplayName,
                        skill.reason?.localizedDisplayName,
                    ].compactMap { $0 }.joined(separator: ". "))
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.08)))
        }
    }

    private func platformResource(_ platform: SkillPlatform) -> LocalizedStringResource {
        switch platform {
        case .codex: LocalizedStringResource("Codex", bundle: SkillsManagerLocalizationResources.bundle)
        case .claude: LocalizedStringResource("Claude Code", bundle: SkillsManagerLocalizationResources.bundle)
        case .opencode: LocalizedStringResource("OpenCode", bundle: SkillsManagerLocalizationResources.bundle)
        case .copilot: LocalizedStringResource("GitHub Copilot", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scan Issues", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.headline)
            ForEach(rootDiagnostics, id: \.self) { diagnostic in
                VStack(alignment: .leading, spacing: 2) {
                    Label(diagnostic.localizedAccessibilitySummary, systemImage: "exclamationmark.triangle")
                    Text(verbatim: diagnostic.root.url.standardizedFileURL.path)
                        .font(.caption2)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
            }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                showingPicker = true
            } label: {
                Text("Choose Folder...", bundle: SkillsManagerLocalizationResources.bundle)
            }

            Button {
                addPath()
            } label: {
                Text("Add", bundle: SkillsManagerLocalizationResources.bundle)
            }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectedURL == nil
                    || validSkillCount == 0
                    || isValidating
                    || (isCollectionMode && selectedAdapter == nil)
                    || libraryRuntime.readiness != .ready
                )
                .keyboardShortcut(.defaultAction)
        }
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            validateAndSetURL(url)
        }
    }

    private func validateAndSetURL(_ url: URL) {
        isValidating = true
        selectedURL = url
        discoveredSkills = [:]
        rootDiagnostics = []
        previewRoots = []
        validSkillCount = 0
        suggestedAdapters = CustomSkillPathMode.suggestedAdapters(for: url)
        selectedAdapter = suggestedAdapters.count == 1 ? suggestedAdapters[0] : nil
        selectedMode = suggestedAdapters.isEmpty
            ? .project
            : .collection(adapter: suggestedAdapters.first ?? .codex)
        rescanSelectedURL()
    }

    private var isCollectionMode: Bool {
        if case .collection = selectedMode { return true }
        return false
    }

    private func rescanSelectedURL() {
        guard let url = selectedURL else { return }
        guard case .collection = selectedMode, selectedAdapter == nil else {
            validateSelectedURL(url, mode: selectedMode)
            return
        }
        // An ambiguous collection root is displayed but cannot be added until an adapter is chosen.
        previewRoots = []
        discoveredSkills = [:]
        rootDiagnostics = []
        validSkillCount = 0
        isValidating = false
    }

    private func validateSelectedURL(_ url: URL, mode: CustomSkillPathMode) {
        isValidating = true
        let customPath = CustomSkillPath(url: url, mode: mode)
        let roots = SkillDiscoveryRootPlan.make(
            homeURL: url,
            customPaths: [customPath]
        ).filter { $0.scope.customPathID == customPath.id }
        previewRoots = roots

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SkillDiscoveryScanner().scan(
                        roots: roots,
                        checkpoint: { try Task.checkCancellation() }
                    )
                }.value
                var discovered: [SkillPlatform: [DiscoveredSkill]] = [:]
                for observation in result.observations {
                    let scopesByPlatform = Dictionary(grouping: observation.scopes) {
                        $0.adapterCode
                    }
                    for (adapterCode, scopes) in scopesByPlatform {
                        guard let adapterCode,
                              let platform = SkillPlatform.allCases.first(where: {
                                  $0.storageKey == adapterCode
                              }) else {
                            continue
                        }
                        let locations = scopes.compactMap(\.pathVariant).sorted()
                        discovered[platform, default: []].append(DiscoveredSkill(
                            id: ([adapterCode, observation.relativeLocatorKey] + locations)
                                .joined(separator: "\u{0}"),
                            displayName: observation.relativeLocator,
                            location: locations.joined(separator: ", "),
                            status: observation.status,
                            reason: observation.reason,
                            isValid: observation.fingerprint != nil
                        ))
                    }
                }
                for platform in discovered.keys {
                    discovered[platform]?.sort {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                            == .orderedAscending
                    }
                }
                discoveredSkills = discovered
                rootDiagnostics = result.rootDiagnostics
                validSkillCount = result.observations.filter { $0.fingerprint != nil }.count
                errorMessage = validSkillCount == 0
                    ? String(localized: "No valid Skill candidates found. Check the actual scan roots and reported diagnostics.", bundle: SkillsManagerLocalizationResources.bundle)
                    : nil
            } catch {
                errorMessage = localizedPathError(error)
            }
            isValidating = false
        }
    }

    private func addPath() {
        guard libraryRuntime.readiness == .ready else {
            errorMessage = libraryRuntime.blockingMessage
            return
        }
        guard let url = selectedURL else { return }
        Task { @MainActor in
            guard libraryRuntime.readiness == .ready else {
                errorMessage = libraryRuntime.blockingMessage
                return
            }
            do {
                if case .collection = selectedMode, selectedAdapter == nil {
                    errorMessage = String(localized: "Choose an adapter for this direct Skill collection root.", bundle: SkillsManagerLocalizationResources.bundle)
                    return
                }
                try await store.addCustomPath(url, mode: selectedMode)
                await store.loadSkills()
                dismiss()
            } catch {
                errorMessage = localizedPathError(error)
            }
        }
    }

    private func localizedPathError(_ error: Error) -> String {
        if error is LibraryPersistenceError {
            return libraryRuntime.blockingMessage
        }
        guard let error = error as? CustomPathError else {
            return error.localizedDescription
        }
        switch error {
        case .directoryNotFound:
            return String(localized: "The selected directory does not exist.", bundle: SkillsManagerLocalizationResources.bundle)
        case .duplicatePath:
            return String(localized: "This path has already been added.", bundle: SkillsManagerLocalizationResources.bundle)
        case .invalidMode:
            return String(localized: "The selected custom path mode is invalid.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }
}
