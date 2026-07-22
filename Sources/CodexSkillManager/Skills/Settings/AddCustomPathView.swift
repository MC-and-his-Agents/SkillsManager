import SwiftUI
import UniformTypeIdentifiers

struct AddCustomPathView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store

    @State private var showingPicker = false
    @State private var selectedURL: URL?
    @State private var errorMessage: String?
    @State private var isValidating = false
    @State private var discoveredSkills: [SkillPlatform: [DiscoveredSkill]] = [:]

    private let fileWorker = SkillFileWorker()

    private struct DiscoveredSkill: Identifiable {
        let id: String
        let name: String
        let displayName: String
    }

    private var totalSkillCount: Int {
        discoveredSkills.values.reduce(0) { $0 + $1.count }
    }

    private var sortedPlatforms: [SkillPlatform] {
        SkillPlatform.allCases.filter { discoveredSkills[$0]?.isEmpty == false }
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
            Text("Add Custom Skill Path")
                .font(.title.bold())
            Text("Select a project folder. Skills will be auto-discovered from platform directories (e.g., .claude/skills, .codex/skills, .codex/skills/public).")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isValidating {
            HStack {
                ProgressView()
                Text("Scanning for skills...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = selectedURL {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderPreview(url: url)
                    if !discoveredSkills.isEmpty {
                        discoveredSkillsView
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a project folder",
                systemImage: "folder.badge.plus",
                description: Text("Choose a folder containing platform skill directories")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        if let error = errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func folderPreview(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(url.lastPathComponent)
                    .font(.headline)
            }
            Text(url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.1)))
    }

    private var discoveredSkillsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Discovered Skills")
                    .font(.headline)
                Spacer()
                Text("\(totalSkillCount) total")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            Text("All skills will be added automatically.")
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
                TagView(text: platform.rawValue, tint: platform.badgeTint)
                Text("\(skills.count) skill(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(platform.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(skills) { skill in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(skill.displayName)
                            .font(.callout)
                        Spacer()
                    }
                    .padding(.leading, 8)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.08)))
        }
    }

    private var actions: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Choose Folder...") { showingPicker = true }

            Button("Add") { addPath() }
                .buttonStyle(.borderedProminent)
                .disabled(selectedURL == nil || totalSkillCount == 0 || isValidating)
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

        Task {
            let fileManager = FileManager.default
            var discovered: [SkillPlatform: [DiscoveredSkill]] = [:]

            for platform in SkillPlatform.allCases {
                let platformURL = platform.skillsURL(in: url)
                guard fileManager.fileExists(atPath: platformURL.path) else { continue }

                do {
                    let scanned = try await fileWorker.scanSkills(at: platformURL, storageKey: "preview")
                    if !scanned.isEmpty {
                        discovered[platform] = scanned.map { skill in
                            DiscoveredSkill(
                                id: skill.id,
                                name: skill.name,
                                displayName: skill.displayName
                            )
                        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                    }
                } catch {
                    // Skip platforms that fail to scan
                }
            }

            discoveredSkills = discovered
            if discovered.isEmpty {
                errorMessage = "No skills found. Make sure the folder contains platform directories like .claude/skills or .codex/skills (including .codex/skills/public) with SKILL.md files."
            } else {
                errorMessage = nil
            }
            isValidating = false
        }
    }

    private func addPath() {
        guard let url = selectedURL else { return }
        do {
            try store.addCustomPath(url)
            Task { await store.loadSkills() }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
