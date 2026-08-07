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

    struct CliStatus {
        let isInstalled: Bool
        let isLoggedIn: Bool
        let username: String?
        let errorMessage: String?
    }

    struct ClawdhubOrigin: Sendable {
        let slug: String
        let version: String?
    }

    var skills: [Skill] = [] {
        didSet {
            installedSkillPlatformIndex = InstalledSkillPlatformIndex(entries: skills.flatMap {
                guard let slug = $0.clawdhubSlug else {
                    return [(slug: String, platform: SkillPlatform)]()
                }
                return $0.enabledPlatforms.map { (slug: slug, platform: $0) }
            })
        }
    }
    var listState: ListState = .idle
    var detailState: DetailState = .idle
    var referenceState: DetailState = .idle
    var selectedSkillID: Skill.ID?
    var selectedMarkdown: String = ""
    var selectedReferenceID: SkillReference.ID?
    var selectedReferenceMarkdown: String = ""
    private(set) var installedSkillPlatformIndex = InstalledSkillPlatformIndex(entries: [])

    private let fileWorker = SkillFileWorker()
    private let cliWorker = ClawdhubCLIWorker()
    private let customPathStore: CustomPathStore
    private let markdownLoader: (@Sendable (URL) async throws -> String)?
    var persistence: JournaledSSOTWriter?

    init(
        customPathStore: CustomPathStore = CustomPathStore(),
        markdownLoader: (@Sendable (URL) async throws -> String)? = nil
    ) {
        self.customPathStore = customPathStore
        self.markdownLoader = markdownLoader
    }

    var customPaths: [CustomSkillPath] {
        customPathStore.customPaths
    }

    func activatePersistence(_ persistence: JournaledSSOTWriter) {
        self.persistence = persistence
    }

    func addCustomPath(_ url: URL) async throws {
        try await customPathStore.addPath(url)
    }

    func removeCustomPath(_ path: CustomSkillPath) async throws {
        try await customPathStore.removePath(path)
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
            guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
            let catalog = try await persistence.managedLocalCatalogReadback()
            let scanned = try await fileWorker.scanSkills(
                at: catalog.root.registeredURL,
                storageKey: "managed"
            )
            let scannedByDirectory = Dictionary(grouping: scanned, by: \.name)
            let expectedDirectories = Set(catalog.skills.map(\.skill.skillID.directoryName))
            guard scannedByDirectory.values.allSatisfy({ $0.count == 1 }),
                  Set(scannedByDirectory.keys) == expectedDirectories else {
                throw ManagedLocalCatalogError.inconsistentCatalog
            }
            let namePairs = catalog.skills.map {
                ($0.skill.skillID, $0.skill.displayName.value)
            }
            guard Set(namePairs.map(\.0)).count == namePairs.count else {
                throw ManagedLocalCatalogError.inconsistentCatalog
            }
            let displayNames = Dictionary(uniqueKeysWithValues: namePairs)

            let skills = try catalog.skills.map { item in
                let directoryName = item.skill.skillID.directoryName
                guard let scannedSkill = scannedByDirectory[directoryName]?.first else {
                    throw ManagedLocalCatalogError.inconsistentCatalog
                }
                let clawdhub = item.providerProvenance.first {
                    $0.identity.provider == "clawdhub"
                }
                let enabledPlatforms = Self.enabledPlatforms(for: item.bindings)
                return Skill(
                    id: item.skill.skillID.directoryName,
                    managedSkillID: item.skill.skillID,
                    name: item.skill.defaultDistributionSlug.value,
                    displayName: item.skill.displayName.value,
                    description: scannedSkill.description,
                    managedStatus: item.skill.status,
                    identitySummary: Self.identitySummary(
                        source: item.source,
                        forkLineage: item.forkLineage,
                        providerProvenance: item.providerProvenance,
                        displayNames: displayNames
                    ),
                    listOrigin: SkillListOriginProjection(
                        hasRepositorySource: item.source != nil,
                        providers: item.providerProvenance.map(\.identity.provider)
                    ),
                    clawdhubSlug: clawdhub?.identity.identifier,
                    clawdhubVersion: clawdhub?.version?.value,
                    enabledPlatforms: enabledPlatforms,
                    managedRoot: scannedSkill.managedRoot,
                    folderURL: scannedSkill.folderURL,
                    skillMarkdownURL: scannedSkill.skillMarkdownURL,
                    references: scannedSkill.references,
                    stats: scannedSkill.stats
                )
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

            await loadSelectedSkill()
        } catch {
            skills = []
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

        let requestedSkillID = selectedSkill.id
        let skillURL = selectedSkill.skillMarkdownURL

        detailState = .loading
        referenceState = .idle
        selectedReferenceID = nil
        selectedReferenceMarkdown = ""

        do {
            let raw = if let markdownLoader {
                try await markdownLoader(skillURL)
            } else {
                try await fileWorker.loadMarkdown(at: skillURL)
            }
            guard selectedSkillID == requestedSkillID else { return }
            selectedMarkdown = stripFrontmatter(from: raw)
            detailState = .loaded
        } catch {
            guard selectedSkillID == requestedSkillID else { return }
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

    func isOwnedSkill(_ skill: Skill) -> Bool {
        skill.clawdhubSlug == nil
    }

    func clawdhubOrigin(for skill: Skill) async -> ClawdhubOrigin? {
        guard let slug = skill.clawdhubSlug else { return nil }
        return ClawdhubOrigin(slug: slug, version: skill.clawdhubVersion)
    }

    func skillNeedsPublish(_ skill: Skill) async -> Bool {
        do {
            guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
            let snapshot = try await persistence.managedSkillPublicationSnapshot(skill.managedSkillID)
            guard let state = try await loadPublishState(for: skill.managedSkillID) else { return true }
            let legacyHash: String? = if state.hashAlgorithmVersion == nil {
                try await fileWorker.computeLegacyPublishHash(for: skill.folderURL)
            } else {
                nil
            }
            try snapshot.requireUnchanged()
            switch state.resolve(currentHash: snapshot.fingerprint, legacyHash: legacyHash) {
            case .unchanged:
                return false
            case .changed:
                return true
            case .migrate(let migratedState):
                try await savePublishState(migratedState, for: skill.managedSkillID)
                return false
            }
        } catch {
            return true
        }
    }

    func publishSkill(
        _ skillID: SkillID,
        bump: PublishBump,
        changelog: String,
        tags: [String],
        publishedVersion: String?
    ) async throws {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        let snapshot = try await persistence.managedSkillPublicationSnapshot(skillID)
        let temporary = try TemporaryItemLease.createDirectory(
            in: FileManager.default.temporaryDirectory,
            prefix: "skillsmanager-publish-"
        )
        defer {
            do {
                try temporary.lease.removeIfCurrent()
            } catch {
                NSLog("Unable to remove frozen publish snapshot: %@", error.localizedDescription)
            }
        }
        try snapshot.copyFiles(
            toDirectoryDescriptor: temporary.handle.descriptor,
            checkpoint: { try Task.checkCancellation() }
        )
        try await cliWorker.publishSkill(
            skillURL: temporary.handle.url,
            publishedVersion: publishedVersion,
            bump: bump,
            changelog: changelog,
            tags: tags
        )
        try await recordPublishedState(for: skillID, hash: snapshot.fingerprint)
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


    func nextVersion(from current: String, bump: PublishBump) -> String? {
        ClawdhubCLIWorker.bumpVersion(current, bump: bump)
    }

    func isNewerVersion(_ latest: String, than installed: String) -> Bool {
        SkillVersionComparison.isNewer(latest, than: installed)
    }

    static func enabledPlatforms(
        for bindings: [DistributionBinding]
    ) -> Set<SkillPlatform> {
        bindings.reduce(into: Set<SkillPlatform>()) { platforms, binding in
            switch binding.scope {
            case .global:
                platforms.formUnion(DistributionTargetCatalog.current.globalReaders)
            case .agent(let platform):
                platforms.insert(platform)
            }
        }
    }

    static func identitySummary(
        source: SkillSourceRecord?,
        forkLineage: SkillForkLineageRecord?,
        providerProvenance: [ProviderProvenanceRecord],
        displayNames: [SkillID: String]
    ) -> String {
        if let forkLineage {
            return "Fork of "
                + (displayNames[forkLineage.parentSkillID]
                    ?? forkLineage.parentSkillID.directoryName)
        }
        if let source {
            guard !source.subpath.value.isEmpty else {
                return source.repositoryURL.value
            }
            return "\(source.repositoryURL.value) · \(source.subpath.value)"
        }
        let providers = Set(providerProvenance.map(\.identity.provider))
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map {
                switch $0 {
                case "clawdhub": "ClawHub"
                case "skills.sh": "skills.sh"
                default: $0
                }
            }
        return providers.isEmpty
            ? "Local"
            : "Discovered via \(providers.joined(separator: ", "))"
    }

}
