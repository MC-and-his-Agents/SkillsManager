import Foundation

nonisolated enum SkillForkOriginType: String, Hashable, Sendable {
    case localFork = "local-fork"
}

nonisolated enum SkillForkLineageError: Error, Equatable {
    case invalidLineage
}

nonisolated struct SkillForkLineageRecord: Hashable, Sendable {
    let forkSkillID: SkillID
    let parentSkillID: SkillID
    let forkedFromFingerprint: SkillContentFingerprint
    let createdAtMilliseconds: Int64
    let originType: SkillForkOriginType

    init(
        forkSkillID: SkillID,
        parentSkillID: SkillID,
        forkedFromFingerprint: SkillContentFingerprint,
        createdAtMilliseconds: Int64,
        originType: SkillForkOriginType = .localFork
    ) throws {
        guard forkSkillID != parentSkillID, createdAtMilliseconds >= 0 else {
            throw SkillForkLineageError.invalidLineage
        }
        self.forkSkillID = forkSkillID
        self.parentSkillID = parentSkillID
        self.forkedFromFingerprint = forkedFromFingerprint
        self.createdAtMilliseconds = createdAtMilliseconds
        self.originType = originType
    }
}
