import Foundation

nonisolated struct ManagedSkillUpdateAdmissionLease: Hashable, Sendable {
    let skillID: SkillID
    fileprivate let token: UUID
}

actor ManagedSkillUpdateAdmission {
    private var leases: [SkillID: UUID] = [:]

    func acquire(_ skillID: SkillID) -> ManagedSkillUpdateAdmissionLease? {
        guard leases[skillID] == nil else { return nil }
        let token = UUID()
        leases[skillID] = token
        return ManagedSkillUpdateAdmissionLease(skillID: skillID, token: token)
    }

    func release(_ lease: ManagedSkillUpdateAdmissionLease) {
        guard leases[lease.skillID] == lease.token else { return }
        leases[lease.skillID] = nil
    }
}
