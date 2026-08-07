#if SKILLS_MANAGER_UI_TEST

import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

// Kept in the fixture-only composition so default binaries cannot accept fixture input.
let SkillsManagerUITestFixtureEnabled = "SkillsManagerUITestFixtureEnabled"

nonisolated enum SkillsManagerUIFixtureProfile: String, Sendable, CaseIterable {
    case baseline
    case empty
    case failureClawHub = "failure-clawhub"
    case failureSkillsSh = "failure-skills-sh"
    case failureRepository = "failure-repository"
    case detailActionBar = "detail-action-bar"
    case feedback
}

struct SkillsManagerUIFixtureRuntime: Sendable {
    let homeURL: URL
    let runnerRootURL: URL
    let profile: SkillsManagerUIFixtureProfile?
    let admissionError: String?
    let remoteClient: RemoteSkillClient
    let skillsShClient: SkillsShSearchClient
    let githubClient: SkillsShGitHubSourceClient

    static func current() -> Self {
        let arguments = CommandLine.arguments
        let profileValue: String?
        if let index = arguments.firstIndex(of: "--skillsmanager-ui-fixture"),
           arguments.indices.contains(index + 1) {
            profileValue = arguments[index + 1]
        } else {
            profileValue = nil
        }
        let profile = profileValue.flatMap(SkillsManagerUIFixtureProfile.init(rawValue:))
        let rootURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
            "SKILLS_MANAGER_UI_TEST_ROOT"
        ] ?? "", isDirectory: true).standardizedFileURL
        let homeURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
            "SKILLS_MANAGER_UI_TEST_HOME"
        ] ?? "", isDirectory: true).standardizedFileURL
        let error = admissionError(
            arguments: arguments,
            profileValue: profileValue,
            profile: profile,
            rootURL: rootURL,
            homeURL: homeURL
        )
        let selected = profile ?? .empty
        return Self(
            homeURL: error == nil ? homeURL : URL(fileURLWithPath: "/dev/null"),
            runnerRootURL: rootURL,
            profile: profile,
            admissionError: error,
            remoteClient: .fixture(profile: selected),
            skillsShClient: .fixture(profile: selected),
            githubClient: .fixture(profile: selected, homeURL: homeURL)
        )
    }

    var isAdmitted: Bool { admissionError == nil && profile != nil }
    var archiveURL: URL {
        homeURL.appendingPathComponent("fixture-multiskill.zip")
    }

    func start() async -> LibraryStartupResult {
        guard isAdmitted, let profile else {
            return Self.blockedResult(admissionError ?? "fixture arguments are required")
        }
        do {
            let coordinator = LibraryStartupCoordinator(homeURL: homeURL)
            let result = await coordinator.start()
            guard result.readiness == .ready, let writer = result.session else {
                return result
            }
            try await seed(profile: profile, writer: writer)
            return result
        } catch {
            return Self.blockedResult("fixture seed failed: \(error.localizedDescription)")
        }
    }

    private func seed(profile: SkillsManagerUIFixtureProfile, writer: JournaledSSOTWriter) async throws {
        guard profile != .empty else { return }
        try createFixtureSources()
        try await seedManagedSkill(writer: writer)
        if profile == .detailActionBar {
            try await seedNeedsRepairSkill(writer: writer)
        }
        if profile == .feedback {
            try await seedNeedsRepairSkill(writer: writer)
            try await seedClawHubManagedSkill(writer: writer)
        }
        try createUnmanagedSkills()
        try await writer.insertCustomPath(CustomSkillPath(
            url: homeURL.appendingPathComponent("fixture-custom-skills", isDirectory: true),
            displayName: "Fixture Custom"
        ))
        try createArchive()
        try await insertRepository(writer: writer)
    }

    private func seedManagedSkill(writer: JournaledSSOTWriter) async throws {
        let sourceURL = homeURL.appendingPathComponent("fixture-source/managed", isDirectory: true)
        let snapshot = try SkillContentSnapshot.capture(at: sourceURL)
        let skillID = SkillID()
        let displayName = try SkillDisplayName("Fixture Managed")
        let skill = try ManagedSkillRecord(
            skillID: skillID,
            displayName: displayName,
            defaultDistributionSlug: try DefaultDistributionSlug(candidateFrom: displayName),
            contentFingerprint: try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest),
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let payload = try SSOTSkillWritePayload(skill: skill)
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
        let configuration = DistributionDesiredConfiguration(
            scope: .global(skill.defaultDistributionSlug),
            syncMode: .symlink
        )
        let plan = try await writer.distributionPlan(
            skillID: skillID,
            desiredConfiguration: configuration,
            requiredAdapterCodes: configuration.scope.requiredAdapterCodes
        )
        guard plan.status == .noOp || plan.status == .executable else { return }
        if plan.status == .executable {
            _ = try await writer.applyDistribution(skillID: skillID, plan: plan)
        }
    }

    private func createFixtureSources() throws {
        let source = homeURL.appendingPathComponent("fixture-source/managed", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# Fixture Managed\n\nA deterministic fixture Skill.\n".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"), options: .atomic)
        try chmodDirectory(source)
    }

    private func seedNeedsRepairSkill(writer: JournaledSSOTWriter) async throws {
        let sourceURL = homeURL.appendingPathComponent("fixture-source/broken", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data("# Fixture Broken\n\nDeterministic needs-repair fixture Skill.\n".utf8)
            .write(to: sourceURL.appendingPathComponent("SKILL.md"), options: .atomic)
        try chmodDirectory(sourceURL)
        let snapshot = try SkillContentSnapshot.capture(at: sourceURL)
        let skillID = SkillID()
        let displayName = try SkillDisplayName("Fixture Broken")
        let skill = try ManagedSkillRecord(
            skillID: skillID,
            displayName: displayName,
            defaultDistributionSlug: try DefaultDistributionSlug(candidateFrom: displayName),
            contentFingerprint: try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest),
            status: .needsRepair,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let payload = try SSOTSkillWritePayload(skill: skill)
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
    }

    private func seedClawHubManagedSkill(writer: JournaledSSOTWriter) async throws {
        let sourceURL = homeURL.appendingPathComponent("fixture-source/clawhub", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data("# ClawHub Managed\n\nDeterministic ClawHub-provenance fixture Skill.\n".utf8)
            .write(to: sourceURL.appendingPathComponent("SKILL.md"), options: .atomic)
        try chmodDirectory(sourceURL)
        let snapshot = try SkillContentSnapshot.capture(at: sourceURL)
        let skillID = SkillID()
        let displayName = try SkillDisplayName("ClawHub Managed")
        let slug = try DefaultDistributionSlug(candidateFrom: displayName)
        let skill = try ManagedSkillRecord(
            skillID: skillID,
            displayName: displayName,
            defaultDistributionSlug: slug,
            contentFingerprint: try SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest),
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let provenance = try ProviderProvenanceRecord(
            skillID: skillID,
            identity: try ProviderAliasIdentity(provider: "clawdhub", identifier: slug.value),
            identifierKey: slug.collisionKey,
            version: try SourceVersion("1.0.0")
        )
        let payload = try SSOTSkillWritePayload(
            skill: skill,
            providerProvenance: [provenance]
        )
        _ = try await writer.create(payload: payload, sourceSnapshot: snapshot)
    }

    private func createUnmanagedSkills() throws {
        let customRoot = homeURL.appendingPathComponent("fixture-custom-skills", isDirectory: true)
        let customSkillRoot = customRoot.appendingPathComponent(
            ".config/opencode/skill",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: customSkillRoot, withIntermediateDirectories: true)
        for name in ["Needs Import One", "Needs Import Two"] {
            let directory = customSkillRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("# \(name)\n\nPending fixture import.\n".utf8)
                .write(to: directory.appendingPathComponent("SKILL.md"), options: .atomic)
            try chmodDirectory(directory)
        }
        try chmodDirectory(customSkillRoot)
        try chmodDirectory(customRoot)
    }

    private func createArchive() throws {
        let archive = archiveURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: archive.path) {
            try fileManager.removeItem(at: archive)
        }
        let entries = [
            ("fixture-one/SKILL.md", Data("# Fixture One\n\nArchive Skill one.\n".utf8)),
            ("fixture-two/SKILL.md", Data("# Fixture Two\n\nArchive Skill two.\n".utf8)),
        ]
        let zip = try Archive(url: archive, accessMode: .create)
        for (path, contents) in entries {
            try zip.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(contents.count)
            ) { position, size in
                let start = Int(position)
                return contents.subdata(in: start..<min(start + size, contents.count))
            }
        }
        var metadata = stat()
        guard Darwin.lstat(archive.path, &metadata) == 0 else { throw CocoaError(.fileWriteUnknown) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func insertRepository(writer: JournaledSSOTWriter) async throws {
        let input = try CustomRepositoryCatalogInput(
            repositoryURL: "https://github.com/fixture/skills",
            requestedRef: .explicit("main"),
            displayName: "Fixture Repository"
        )
        _ = try await writer.insertCustomRepository(input)
    }

    private static func admissionError(
        arguments: [String],
        profileValue: String?,
        profile: SkillsManagerUIFixtureProfile?,
        rootURL: URL,
        homeURL: URL
    ) -> String? {
        guard arguments.filter({ $0 == "--skillsmanager-ui-fixture" }).count == 1,
              profileValue != nil else { return "fixture profile is required" }
        guard profile != nil else { return "fixture profile is not allowlisted" }
        guard absolute(rootURL), absolute(homeURL) else { return "fixture paths must be absolute" }
        guard metadata(rootURL, expectedMode: 0o700) != nil else {
            return "fixture runner root failed owner/mode admission"
        }
        guard metadata(homeURL, expectedMode: 0o700) != nil else {
            return "fixture home failed owner/mode admission"
        }
        guard homeURL.deletingLastPathComponent().standardizedFileURL == rootURL else {
            return "fixture home must be a direct child of the runner root"
        }
        guard let before = identity(rootURL), let parent = identity(homeURL) else {
            return "fixture path identity is unavailable"
        }
        _ = parent
        guard identity(rootURL) == before else { return "fixture runner root changed" }
        return nil
    }

    private static func absolute(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && url.path != "/"
    }

    private static func metadata(_ url: URL, expectedMode: mode_t) -> stat? {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0,
              value.st_uid == Darwin.geteuid(),
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              value.st_mode & 0o7777 == expectedMode else { return nil }
        return value
    }

    private static func identity(_ url: URL) -> ManagedItemIdentity? {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { return nil }
        return ManagedItemIdentity(value)
    }

    private static func blockedResult(_ message: String) -> LibraryStartupResult {
        _ = message
        return LibraryStartupResult(
            phase: .classifying,
            readiness: .blocked,
            diagnostics: [.make(.unrecoverable, subjectKind: .library, subjectID: "uiFixture")],
            outcome: nil,
            session: nil
        )
    }

    private func chmodDirectory(_ url: URL) throws {
        guard Darwin.chmod(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

private extension RemoteSkillClient {
    static func fixture(profile: SkillsManagerUIFixtureProfile) -> Self {
        let shouldFail = profile == .failureClawHub
        let empty = profile == .empty
        let latest = (1...13).map { index in
            RemoteSkill(
                id: "fixture-clawhub-\(index)", slug: "fixture-clawhub-\(index)",
                displayName: "ClawHub Fixture \(index)", summary: "Fixed ClawHub result \(index)",
                latestVersion: "1.0.0", updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                downloads: index * 10, stars: index
            )
        }
        return Self(
            fetchLatest: { _, cursor in
                guard !shouldFail else { throw RemoteSkillClientError.providerUnavailable }
                guard !empty else { return RemoteSkillPage(items: [], nextCursor: nil) }
                return cursor == nil
                    ? RemoteSkillPage(items: Array(latest.prefix(1)), nextCursor: "page-2")
                    : RemoteSkillPage(items: Array(latest.prefix(2).suffix(1)), nextCursor: nil)
            },
            search: { query, limit in
                guard !shouldFail else { throw RemoteSkillClientError.providerUnavailable }
                guard !empty else { return [] }
                let searchItems = (1...26).map { index in
                    RemoteSkill(
                        id: "fixture-clawhub-search-\(index)", slug: "fixture-clawhub-search-\(index)",
                        displayName: "ClawHub Search \(query) \(index)",
                        summary: "Fixed ClawHub search result \(index)",
                        latestVersion: "1.0.0", updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        downloads: index * 10, stars: index
                    )
                }
                return limit <= 20 ? Array(searchItems.prefix(20)) : searchItems
            },
            download: { _, _ in
                throw RemoteSkillClientError.providerUnavailable
            },
            fetchDetail: { _ in nil },
            fetchLatestVersion: { slug in
                if profile == .feedback {
                    return "1.0.1"
                }
                return "1.0.0"
            }
        )
    }
}

private extension SkillsShSearchClient {
    static func fixture(profile: SkillsManagerUIFixtureProfile) -> Self {
        let shouldFail = profile == .failureSkillsSh
        let empty = profile == .empty
        let items = (1...21).map { index in
            SkillsShSearchItem(
                id: "fixture-skills-sh-\(index)", skillID: "fixture-skill-\(index)",
                name: "skills.sh Fixture \(index)", installs: UInt64(index * 100),
                source: "fixture/source-\(index)"
            )
        }
        return Self { query, limit, _ in
            guard !shouldFail else { throw SkillsShSearchError.providerUnavailable }
            guard !empty else { return SkillsShSearchPage(query: query, items: [], reportedCount: 0) }
            let page = limit <= 20 ? Array(items.prefix(20)) : items
            return SkillsShSearchPage(query: query, items: page, reportedCount: items.count)
        }
    }
}

private extension SkillsShGitHubSourceClient {
    static func fixture(
        profile: SkillsManagerUIFixtureProfile,
        homeURL: URL
    ) -> Self {
        let shouldFail = profile == .failureRepository
        let repositoryURL = try! NormalizedRepositoryURL("https://github.com/fixture/skills")
        let subpath = try! RepositorySubpath("skills/repository")
        let commit = String(repeating: "a", count: 40)
        let tree = String(repeating: "b", count: 40)
        let alias = try! ProviderAliasIdentity.github(
            repositoryURL: repositoryURL,
            subpath: subpath
        )
        let skillContents = Data(
            "# Repository Fixture Skill\n\nDeterministic repository archive.\n".utf8
        )
        let blobs = [
            SkillsShGitHubBlob(
                relativePath: "SKILL.md",
                mode: "100644",
                size: skillContents.count,
                gitBlobSHA: SkillsManagerUIFixtureRuntime.gitBlobSHA(skillContents)
            ),
        ]
        let downloadArchive: @Sendable () async throws -> Data = {
            try SkillsManagerUIFixtureRuntime.repositoryArchiveData(
                contents: skillContents,
                at: homeURL
            )
        }
        let discovery: @Sendable (CustomRepositoryCatalogRecord) async throws
            -> CustomRepositoryDiscovery = { catalog in
            guard !shouldFail else { throw SkillsShGitHubSourceError.providerUnavailable }
            return CustomRepositoryDiscovery(
                repositoryID: catalog.repositoryID,
                databaseRevision: catalog.databaseRevision,
                repositoryURL: catalog.repositoryURL,
                requestedRef: catalog.requestedRef,
                commitSHA: commit,
                treeSHA: tree,
                candidates: [CustomRepositoryDiscoveryCandidate(
                    subpath: subpath,
                    displayName: "Repository Fixture Skill",
                    providerAlias: alias
                )]
            )
        }
        let resolved = SkillsShResolvedGitHubSource(
            repositoryURL: repositoryURL,
            owner: "fixture",
            repository: "skills",
            defaultBranch: "main",
            commitSHA: commit,
            treeSHA: tree,
            subpath: subpath,
            blobs: blobs,
            archiveURL: URL(string: "https://api.github.com/repos/fixture/skills/zipball/\(commit)")!,
            providerAliasIdentifier: alias.identifier,
            defaultDistributionSlug: try! DefaultDistributionSlug(validating: "repository-fixture")
        )
        let resolvedExisting = SkillsShResolvedGitHubUpdateSource(
            repositoryURL: repositoryURL, owner: "fixture", repository: "skills",
            defaultBranch: "main", commitSHA: commit, treeSHA: tree, subpath: subpath,
            blobs: blobs, archiveURL: resolved.archiveURL
        )
        let archive: @Sendable () async throws -> SkillsShGitHubArchive = {
            guard !shouldFail else { throw SkillsShGitHubSourceError.providerUnavailable }
            return SkillsShGitHubArchive(
                data: try await downloadArchive(),
                sourceURL: resolved.archiveURL
            )
        }
        return Self(
            resolve: { _, _, _ in resolved },
            download: { _ in try await archive() },
            resolveExisting: { _, _ in resolvedExisting },
            downloadExisting: { _ in try await archive() },
            currentCommitSHA: { _ in commit },
            discoverRepository: discovery,
            resolveCustomRepository: { _ in resolvedExisting }
        )
    }
}

private extension SkillsManagerUIFixtureRuntime {
    nonisolated static func repositoryArchiveData(contents: Data, at homeURL: URL) throws -> Data {
        let archiveURL = homeURL.appendingPathComponent("fixture-repository.zip")
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            return try Data(contentsOf: archiveURL)
        }
        let zip = try Archive(url: archiveURL, accessMode: .create)
        try zip.addEntry(
            with: "wrapper/skills/repository/SKILL.md",
            type: .file,
            uncompressedSize: Int64(contents.count),
            permissions: 0o644
        ) { position, size in
            let start = Int(position)
            return contents.subdata(in: start..<min(start + size, contents.count))
        }
        return try Data(contentsOf: archiveURL)
    }

    nonisolated static func gitBlobSHA(_ contents: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(contents.count)\0".utf8))
        hasher.update(data: contents)
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }
}

#endif
