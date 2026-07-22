import Foundation

struct RemoteSkill: Identifiable, Hashable {
    let id: String
    let slug: String
    let displayName: String
    let summary: String?
    let latestVersion: String?
    let updatedAt: Date?
    let downloads: Int?
    let stars: Int?
}

struct RemoteSkillOwner: Hashable {
    let handle: String?
    let displayName: String?
    let imageURL: String?
}
