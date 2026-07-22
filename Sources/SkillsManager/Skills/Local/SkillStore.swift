import CryptoKit
import Foundation
import Observation

@MainActor
@Observable final class SkillStore {
    enum ListState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum DetailState: Equatable {
        case idle
        case loading
        case loaded
        case missing
        case failed(String)
    }

    struct LocalSkillGroup: Identifiable {
        let id: Skill.ID
        let skill: Skill
        let installedPlatforms: Set<SkillPlatform>
        let deleteIDs: [Skill.ID]
    }

    struct CliStatus {
        let isInstalled: Bool
        let isLoggedIn: Bool
        let username: String?
        let errorMessage: String?
    }

    var skills: [Skill] = []
    var listState: ListState = .idle
    var detailState: DetailState = .idle
    var referenceState: DetailState = .idle
    var selectedSkillID: Skill.ID?
    var selectedMarkdown: String = ""
    var selectedReferenceID: SkillReference.ID?
    var selectedReferenceMarkdown: String = ""
    var deleteErrorMessage: String?

    private let fileWorker = SkillFileWorker()
    private let importWorker = SkillImportWorker()
    private let cliWorker = ClawdhubCLIWorker()
    private let customPathStore: CustomPathStore

    init(customPathStore: CustomPathStore = CustomPathStore()) {
        self.customPathStore = customPathStore
    }

    var customPaths: [CustomSkillPath] {
        customPathStore.customPaths
    }

    func addCustomPath(_ url: URL) throws {
        try customPathStore.addPath(url)
    }

    func removeCustomPath(_ path: CustomSkillPath) {
        customPathStore.removePath(path)
    }

    var selectedSkill: Skill? {
        skills.first { $0.id == selectedSkillID }
    }

    var selectedReference: SkillReference? {
        guard let selectedSkill, let selectedReferenceID else { return nil }
        return selectedSkill.references.first { $0.id == selectedReferenceID }
    }

    func loadSkills() async {
        listState = .loading
        detailState = .idle
        referenceState = .idle
        do {
            let platforms = SkillPlatform.allCases.flatMap { platform in
                zip(platform.relativePaths, platform.rootURLs).map { relativePath, rootURL in
                    (platform, rootURL, platform.storageKey(forRelativePath: relativePath))
                }
            }
            var skills: [Skill] = []

            // Scan platform paths
            for (platform, rootURL, storageKey) in platforms {
                let scanned = try await fileWorker.scanSkills(at: rootURL, storageKey: storageKey)
                skills.append(contentsOf: scanned.map { scannedSkill in
                    Skill(
                        id: scannedSkill.id,
                        name: scannedSkill.name,
                        displayName: scannedSkill.displayName,
                        description: scannedSkill.description,
                        platform: platform,
                        customPath: nil,
                        managedRoot: scannedSkill.managedRoot,
                        folderURL: scannedSkill.folderURL,
                        skillMarkdownURL: scannedSkill.skillMarkdownURL,
                        references: scannedSkill.references,
                        stats: scannedSkill.stats
                    )
                })
            }

            // Scan custom paths - auto-discover platform subpaths
            let fileManager = FileManager.default
            for customPath in customPathStore.customPaths {
                for platform in SkillPlatform.allCases {
                    for (relativePath, platformURL) in zip(platform.relativePaths, platform.skillsURLs(in: customPath.url)) {
                        guard fileManager.fileExists(atPath: platformURL.path) else { continue }

                        let storageKey = "\(customPath.storageKey)-\(platform.storageKey(forRelativePath: relativePath))"
                        let scanned = try await fileWorker.scanSkills(at: platformURL, storageKey: storageKey)
                        skills.append(contentsOf: scanned.map { scannedSkill in
                            Skill(
                                id: scannedSkill.id,
                                name: scannedSkill.name,
                                displayName: scannedSkill.displayName,
                                description: scannedSkill.description,
                                platform: platform,
                                customPath: customPath,
                                managedRoot: scannedSkill.managedRoot,
                                folderURL: scannedSkill.folderURL,
                                skillMarkdownURL: scannedSkill.skillMarkdownURL,
                                references: scannedSkill.references,
                                stats: scannedSkill.stats
                            )
                        })
                    }
                }
            }

            self.skills = skills.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            listState = .loaded
            if let selectedSkillID,
               self.skills.contains(where: { $0.id == selectedSkillID }) == false {
                self.selectedSkillID = self.skills.first?.id
            } else if selectedSkillID == nil {
                selectedSkillID = self.skills.first?.id
            }

            normalizeSelectionToPreferredPlatform()
            await loadSelectedSkill()
        } catch {
            listState = .failed(error.localizedDescription)
        }
    }

    func loadSelectedSkill() async {
        guard let selectedSkill else {
            detailState = .idle
            selectedMarkdown = ""
            referenceState = .idle
            selectedReferenceID = nil
            selectedReferenceMarkdown = ""
            return
        }

        let skillURL = selectedSkill.skillMarkdownURL

        detailState = .loading
        referenceState = .idle
        selectedReferenceID = nil
        selectedReferenceMarkdown = ""

        do {
            let raw = try await fileWorker.loadMarkdown(at: skillURL)
            selectedMarkdown = stripFrontmatter(from: raw)
            detailState = .loaded
        } catch {
            detailState = .failed(error.localizedDescription)
            selectedMarkdown = ""
        }
    }

    func selectReference(_ reference: SkillReference) async {
        selectedReferenceID = reference.id
        await loadSelectedReference()
    }

    func loadSelectedReference() async {
        guard let selectedReference else {
            referenceState = .idle
            selectedReferenceMarkdown = ""
            return
        }

        referenceState = .loading

        do {
            let raw = try await fileWorker.loadMarkdown(at: selectedReference.url)
            selectedReferenceMarkdown = stripFrontmatter(from: raw)
            referenceState = .loaded
        } catch {
            referenceState = .failed(error.localizedDescription)
            selectedReferenceMarkdown = ""
        }
    }

    func deleteSkills(ids: [Skill.ID]) async {
        deleteErrorMessage = nil
        var failures: [String] = []
        for id in ids {
            guard let skill = skills.first(where: { $0.id == id }) else { continue }
            do {
                try ManagedSkillRemoval.remove(
                    targetURL: skill.folderURL,
                    managedRoot: skill.managedRoot
                )
            } catch {
                failures.append("\(skill.displayName): \(error.localizedDescription)")
            }
        }
        await loadSkills()
        if !failures.isEmpty {
            deleteErrorMessage = failures.joined(separator: "\n")
        }
    }

    func isOwnedSkill(_ skill: Skill) -> Bool {
        // Skills from custom paths are always considered "owned"
        if skill.customPath != nil {
            return true
        }
        let originURL = skill.folderURL
            .appendingPathComponent(".clawdhub")
            .appendingPathComponent("origin.json")
        return !FileManager.default.fileExists(atPath: originURL.path)
    }

    func clawdhubOrigin(for skill: Skill) async -> SkillFileWorker.ClawdhubOrigin? {
        await fileWorker.readClawdhubOrigin(from: skill.folderURL)
    }

    func isInstalled(slug: String) -> Bool {
        skills.contains { SkillContentPath.namesAreEquivalent($0.name, slug) }
    }

    func isInstalled(slug: String, in platform: SkillPlatform) -> Bool {
        skills.contains {
            SkillContentPath.namesAreEquivalent($0.name, slug) && $0.platform == platform
        }
    }

    var installedSkillPlatformIndex: InstalledSkillPlatformIndex {
        InstalledSkillPlatformIndex(entries: skills.compactMap { skill in
            skill.platform.map { (slug: skill.name, platform: $0) }
        })
    }

    func installedPlatforms(for slug: String) -> Set<SkillPlatform> {
        installedSkillPlatformIndex.platforms(forSlug: slug)
    }

    func groupedLocalSkills(from filteredSkills: [Skill]) -> [LocalSkillGroup] {
        let grouped = Dictionary(grouping: filteredSkills) {
            SkillContentPath.collisionKey(for: $0.name)
        }
        let preferredPlatformOrder: [SkillPlatform] = [.codex, .claude, .opencode, .copilot]

        return grouped.compactMap { _, filteredSkills in
            guard let preferredSelection = preferredPlatformOrder
                .compactMap({ platform in filteredSkills.first(where: { $0.platform == platform }) })
                .first ?? filteredSkills.first else {
                return nil
            }

            let preferredContent = preferredPlatformOrder
                .compactMap({ platform in filteredSkills.first(where: { $0.platform == platform }) })
                .first ?? preferredSelection

            // Limit platforms to the filtered scope (e.g. custom path sections).
            let installedPlatforms = Set(filteredSkills.compactMap(\.platform))

            return LocalSkillGroup(
                id: preferredSelection.id,
                skill: preferredContent,
                installedPlatforms: installedPlatforms,
                deleteIDs: filteredSkills.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            lhs.skill.displayName.localizedCaseInsensitiveCompare(rhs.skill.displayName) == .orderedAscending
        }
    }

    func groupedPlatformSkills(from skills: [Skill]) -> [LocalSkillGroup] {
        groupedLocalSkills(from: skills.filter { $0.customPath == nil })
    }

    func skillsForCustomPath(_ path: CustomSkillPath) -> [Skill] {
        skills.filter { $0.customPath?.id == path.id }
    }

    func platformSkills() -> [Skill] {
        skills.filter { $0.platform != nil }
    }

    func skillNeedsPublish(_ skill: Skill) async -> Bool {
        do {
            let hash = try await fileWorker.computeSkillHash(for: skill.folderURL)
            guard let state = loadPublishState(for: skill.name) else { return true }
            let legacyHash: String? = if state.hashAlgorithmVersion == nil {
                try await fileWorker.computeLegacyPublishHash(for: skill.folderURL)
            } else {
                nil
            }
            switch state.resolve(currentHash: hash, legacyHash: legacyHash) {
            case .unchanged:
                return false
            case .changed:
                return true
            case .migrate(let migratedState):
                savePublishState(migratedState, for: skill.name)
                return false
            }
        } catch {
            return true
        }
    }

    func publishSkill(
        _ skill: Skill,
        bump: PublishBump,
        changelog: String,
        tags: [String],
        publishedVersion: String?
    ) async throws {
        try await cliWorker.publishSkill(
            skillURL: skill.folderURL,
            publishedVersion: publishedVersion,
            bump: bump,
            changelog: changelog,
            tags: tags
        )

        let hash = try await fileWorker.computeSkillHash(for: skill.folderURL)
        savePublishState(for: skill.name, hash: hash)
    }

    func fetchClawdhubStatus() async -> CliStatus {
        let status = await cliWorker.fetchStatus()
        return CliStatus(
            isInstalled: status.isInstalled,
            isLoggedIn: status.isLoggedIn,
            username: status.username,
            errorMessage: status.errorMessage
        )
    }


    func normalizeSelectionToPreferredPlatform() {
        guard let selectedSkillID,
              let selected = skills.first(where: { $0.id == selectedSkillID }) else {
            return
        }

        let slug = selected.name
        let candidates = skills.filter {
            SkillContentPath.namesAreEquivalent($0.name, slug)
        }
        guard candidates.count > 1 else { return }

        let preferredOrder: [SkillPlatform] = [.codex, .claude, .opencode, .copilot]
        let preferred = preferredOrder
            .compactMap { platform in candidates.first(where: { $0.platform == platform }) }
            .first ?? candidates.first
        if let preferred, preferred.id != selectedSkillID {
            self.selectedSkillID = preferred.id
        }
    }

    func installRemoteSkill(
        _ skill: RemoteSkill,
        client: RemoteSkillClient,
        destinations: Set<SkillPlatform>
    ) async throws -> String? {
        guard !destinations.isEmpty else {
            throw NSError(domain: "RemoteSkill", code: 3)
        }

        let zipURL = try await client.download(skill.slug, skill.latestVersion)
        let destinationList = destinations.map { platform in
            if let existing = skills.first(where: {
                SkillContentPath.namesAreEquivalent($0.name, skill.slug)
                    && $0.platform == platform
                    && $0.customPath == nil
            }) {
                return SkillFileWorker.InstallDestination(
                    rootURL: existing.managedRoot.registeredURL,
                    storageKey: storageKey(for: existing),
                    managedRoot: existing.managedRoot
                )
            }
            return SkillFileWorker.InstallDestination(
                rootURL: platform.rootURL,
                storageKey: platform.storageKey
            )
        }
        let result: SkillFileWorker.RemoteInstallResult
        do {
            result = try await fileWorker.installRemoteSkill(
                zipURL: zipURL,
                slug: skill.slug,
                version: skill.latestVersion,
                destinations: destinationList
            )
        } catch {
            await loadSkills()
            throw error
        }

        await loadSkills()
        if let selectedID = result.selectedID {
            self.selectedSkillID = selectedID
        }
        return result.report.warningMessage
    }

    func updateInstalledSkill(
        slug: String,
        version: String?,
        client: RemoteSkillClient
    ) async throws -> String? {
        let installedSkills = skills.filter {
            SkillContentPath.namesAreEquivalent($0.name, slug)
                && $0.platform != nil
                && $0.customPath == nil
        }
        guard !installedSkills.isEmpty else { return nil }

        var seenRootIdentities: Set<ManagedItemIdentity> = []
        var destinationList: [SkillFileWorker.InstallDestination] = []
        for installed in installedSkills {
            let rootIdentity = try installed.managedRoot.verifiedRoot().identity
            guard seenRootIdentities.insert(rootIdentity).inserted else { continue }
            destinationList.append(SkillFileWorker.InstallDestination(
                rootURL: installed.managedRoot.registeredURL,
                storageKey: storageKey(for: installed),
                managedRoot: installed.managedRoot
            ))
        }
        let zipURL = try await client.download(slug, version)
        let result: SkillFileWorker.RemoteInstallResult
        do {
            result = try await fileWorker.installRemoteSkill(
                zipURL: zipURL,
                slug: slug,
                version: version,
                destinations: destinationList
            )
        } catch {
            await loadSkills()
            throw error
        }

        await loadSkills()
        if let selectedID = result.selectedID {
            self.selectedSkillID = selectedID
        }
        return result.report.warningMessage
    }

    private func storageKey(for skill: Skill) -> String {
        let suffix = "-\(skill.name)"
        guard skill.id.hasSuffix(suffix) else { return skill.platform?.storageKey ?? skill.id }
        return String(skill.id.dropLast(suffix.count))
    }

    func nextVersion(from current: String, bump: PublishBump) -> String? {
        ClawdhubCLIWorker.bumpVersion(current, bump: bump)
    }

    func isNewerVersion(_ latest: String, than installed: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let installedParts = installed.split(separator: ".").compactMap { Int($0) }
        guard latestParts.count == 3, installedParts.count == 3 else { return false }
        for index in 0..<3 {
            if latestParts[index] != installedParts[index] {
                return latestParts[index] > installedParts[index]
            }
        }
        return false
    }

}
