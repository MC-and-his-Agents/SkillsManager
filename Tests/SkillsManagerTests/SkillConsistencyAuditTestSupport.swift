import Foundation

@testable import SkillsManager

func equivalentObservation(
    rawLocator: String,
    root: SkillDiscoveryRoot,
    identity: ManagedItemIdentity
) -> SkillDiscoveryObservation {
    SkillDiscoveryObservation(
        roots: [root],
        rootIdentity: identity,
        rawRelativeLocator: rawLocator,
        relativeLocator: "\u{e9}",
        relativeLocatorKey: SkillContentPath.collisionKey(for: "\u{e9}"),
        candidateIdentity: identity,
        symbolicLinkIdentity: nil,
        fingerprint: nil,
        providerAliases: [],
        status: .conflict,
        reason: .scopeSlugConflict,
        matchedSkillID: nil,
        matchedSourceKey: nil
    )
}
