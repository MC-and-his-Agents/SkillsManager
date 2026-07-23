import Foundation

nonisolated struct DistributionTarget: Hashable, Sendable {
    let scope: DistributionBindingScope
    let rootLocator: String

    var rank: Int { scope.canonicalRank }
}

nonisolated struct DistributionTargetEntry: Hashable, Sendable {
    let target: DistributionTarget
    let distributionSlug: DefaultDistributionSlug
    let canonicalLocator: String

    var slugKey: String { distributionSlug.collisionKey }
}

nonisolated struct DistributionTargetCatalog: Sendable {
    static let current = DistributionTargetCatalog(
        globalTarget: DistributionTarget(scope: .global, rootLocator: "~/.agents/skills"),
        dedicatedTargets: Dictionary(uniqueKeysWithValues: SkillPlatform.allCases.map {
            (
                $0,
                DistributionTarget(
                    scope: .agent($0),
                    rootLocator: "~/\($0.dedicatedDistributionRelativePath)"
                )
            )
        })
    )

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
