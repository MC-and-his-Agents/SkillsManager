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
}
