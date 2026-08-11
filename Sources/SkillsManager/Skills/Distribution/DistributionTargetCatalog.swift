import Foundation

nonisolated struct DistributionTarget: Hashable, Sendable {
    let scope: DistributionBindingScope
    let rootLocator: String
    /// Resolved target root used for filesystem operations. Defaults retain
    /// the legacy home-relative behavior when this is nil.
    let resolvedRootURL: URL?
    let isConfigured: Bool
    let isAvailable: Bool
    let resolutionStatus: HarnessSkillRootResolutionStatus?

    var rank: Int { scope.canonicalRank }

    init(
        scope: DistributionBindingScope,
        rootLocator: String,
        resolvedRootURL: URL? = nil,
        isConfigured: Bool = false,
        isAvailable: Bool = true,
        resolutionStatus: HarnessSkillRootResolutionStatus? = nil
    ) {
        self.scope = scope
        self.rootLocator = rootLocator
        self.resolvedRootURL = resolvedRootURL
        self.isConfigured = isConfigured
        self.isAvailable = isAvailable
        self.resolutionStatus = resolutionStatus
    }
}

nonisolated struct DistributionTargetEntry: Hashable, Sendable {
    let target: DistributionTarget
    let distributionSlug: DefaultDistributionSlug
    let canonicalLocator: String

    var slugKey: String { distributionSlug.collisionKey }
}

nonisolated struct DistributionTargetCatalog: Sendable {
    static var current: DistributionTargetCatalog {
        current(homeURL: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func current(
        homeURL: URL,
        configurationStore: HarnessSkillRootConfigurationStore = .shared
    ) -> DistributionTargetCatalog {
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let normalizedHome = homeURL.standardizedFileURL
        let global = DistributionTarget(
            scope: .global,
            rootLocator: normalizedHome == defaultHome
                ? "~/.agents/skills"
                : normalizedHome.appendingPathComponent(".agents/skills").path,
            resolvedRootURL: nil
        )
        let dedicated = Dictionary(uniqueKeysWithValues: SkillPlatform.allCases.map { platform in
            let resolution = configurationStore.resolution(for: platform, homeURL: normalizedHome)
            let relativeDefault = normalizedHome.appendingPathComponent(
                platform.dedicatedDistributionRelativePath,
                isDirectory: true
            ).standardizedFileURL
            let configured = resolution.configuration != nil
            let rootURL = configured
                ? (resolution.configuration?.canonicalURL ?? resolution.registeredURL)
                : nil
            let locator = configured
                ? resolution.registeredURL.path
                : normalizedHome == defaultHome
                    ? "~/\(platform.dedicatedDistributionRelativePath)"
                    : relativeDefault.path
            return (
                platform,
                DistributionTarget(
                    scope: .agent(platform),
                    rootLocator: locator,
                    resolvedRootURL: rootURL,
                    isConfigured: configured,
                    isAvailable: !configured || resolution.status == .configured,
                    resolutionStatus: configured ? resolution.status : nil
                )
            )
        })
        return DistributionTargetCatalog(
            globalTarget: global,
            dedicatedTargets: dedicated
        )
    }

    let globalTarget: DistributionTarget
    private let dedicatedTargets: [SkillPlatform: DistributionTarget]

    init(
        globalTarget: DistributionTarget,
        dedicatedTargets: [SkillPlatform: DistributionTarget]
    ) {
        self.globalTarget = globalTarget
        self.dedicatedTargets = dedicatedTargets
    }

    var globalReaders: [SkillPlatform] {
        SkillPlatform.allCases.filter(\.readsGlobalDistributionTarget)
    }

    func target(for scope: DistributionBindingScope) -> DistributionTarget? {
        switch scope {
        case .global:
            globalTarget
        case .agent(let adapter):
            dedicatedTargets[adapter]
        }
    }

    func entry(
        for scope: DistributionBindingScope,
        slug: DefaultDistributionSlug
    ) -> DistributionTargetEntry? {
        guard let target = target(for: scope) else { return nil }
        return DistributionTargetEntry(
            target: target,
            distributionSlug: slug,
            canonicalLocator: "\(target.rootLocator)/\(slug.value)"
                .precomposedStringWithCanonicalMapping
        )
    }

    func ssotLocator(for skillID: SkillID) -> String {
        "~/.SkillsManager/skills/\(skillID.directoryName)"
    }

    /// Parses the target locator captured in a journal plan without consulting
    /// the mutable current catalog. A changed root is handled as stale during
    /// recovery instead of making the persisted payload look corrupt.
    static func persistedTarget(
        from locator: String,
        for scope: DistributionBindingScope
    ) -> (rootLocator: String, slug: DefaultDistributionSlug)? {
        guard locator == locator.precomposedStringWithCanonicalMapping,
              !locator.contains("\0"),
              let component = locator.split(separator: "/", omittingEmptySubsequences: true).last,
              let slug = try? DefaultDistributionSlug(validating: String(component)) else {
            return nil
        }
        let suffix = "/\(slug.value)"
        guard locator.hasSuffix(suffix) else { return nil }
        let rootLocator = String(locator.dropLast(suffix.count))
        guard !rootLocator.isEmpty else { return nil }

        if locator.hasPrefix("~/") {
            let expectedRoot = "~/" + scope.relativeDistributionPath
            guard rootLocator == expectedRoot else { return nil }
        } else {
            guard locator.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: locator, isDirectory: true)
            guard url.standardizedFileURL.path == locator,
                  rootLocator != "/",
                  URL(fileURLWithPath: rootLocator, isDirectory: true)
                    .standardizedFileURL.path == rootLocator else {
                return nil
            }
        }
        return (rootLocator, slug)
    }
}

private extension DistributionBindingScope {
    nonisolated var relativeDistributionPath: String {
        switch self {
        case .global:
            ".agents/skills"
        case .agent(let platform):
            platform.dedicatedDistributionRelativePath
        }
    }
}
