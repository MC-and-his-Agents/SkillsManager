import Foundation

nonisolated func skillDiscoveryPathComponentPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    let left = SkillContentPath.normalizedComponent(lhs)
    let right = SkillContentPath.normalizedComponent(rhs)
    return left.utf8.lexicographicallyPrecedes(right.utf8)
}

nonisolated func skillDiscoveryObservationPrecedes(
    _ lhs: SkillDiscoveryObservation,
    _ rhs: SkillDiscoveryObservation
) -> Bool {
    let leftScope = lhs.scopes.map(\.sortKey).joined(separator: "\u{0}")
    let rightScope = rhs.scopes.map(\.sortKey).joined(separator: "\u{0}")
    if leftScope != rightScope { return leftScope < rightScope }
    if lhs.relativeLocator != rhs.relativeLocator {
        return lhs.relativeLocator.utf8.lexicographicallyPrecedes(rhs.relativeLocator.utf8)
    }
    return lhs.rawRelativeLocator.utf8.lexicographicallyPrecedes(rhs.rawRelativeLocator.utf8)
}

nonisolated func skillDiscoveryDiagnosticPrecedes(
    _ lhs: SkillDiscoveryRootDiagnostic,
    _ rhs: SkillDiscoveryRootDiagnostic
) -> Bool {
    (lhs.root.scope.sortKey, lhs.root.url.path, lhs.reason.rawValue)
        < (rhs.root.scope.sortKey, rhs.root.url.path, rhs.reason.rawValue)
}

nonisolated func skillDiscoveryObservedRootPrecedes(
    _ lhs: SkillDiscoveryObservedRoot,
    _ rhs: SkillDiscoveryObservedRoot
) -> Bool {
    (lhs.root.scope.sortKey, lhs.root.url.path)
        < (rhs.root.scope.sortKey, rhs.root.url.path)
}
