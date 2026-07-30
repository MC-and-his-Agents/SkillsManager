import Foundation

nonisolated struct ManagedLocalSkillReadback: Sendable {
    let skill: ManagedSkillRecord
    let source: SkillSourceRecord?
    let providerProvenance: [ProviderProvenanceRecord]
    let forkLineage: SkillForkLineageRecord?
    let bindings: [DistributionBinding]
}

nonisolated struct ManagedLocalCatalogReadback: Sendable {
    let root: ManagedRootReference
    let skills: [ManagedLocalSkillReadback]
}

nonisolated enum ManagedLocalCatalogError: LocalizedError {
    case inconsistentCatalog
    case skillUnavailable
    case skillNeedsRepair

    var errorDescription: String? {
        switch self {
        case .inconsistentCatalog:
            "The managed Skill catalog does not match the SSOT library."
        case .skillUnavailable:
            "The managed Skill is no longer available."
        case .skillNeedsRepair:
            "The managed Skill needs repair before it can be published."
        }
    }
}
