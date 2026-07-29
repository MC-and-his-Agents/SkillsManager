import Foundation

nonisolated struct RemoteSkill: Identifiable, Hashable, Sendable {
    let id: String
    let slug: String
    let displayName: String
    let summary: String?
    let latestVersion: String?
    let updatedAt: Date?
    let downloads: Int?
    let stars: Int?
}

nonisolated struct RemoteSkillOwner: Hashable, Sendable {
    let handle: String?
    let displayName: String?
    let imageURL: String?
}
