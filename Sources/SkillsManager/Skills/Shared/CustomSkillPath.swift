import Foundation

struct CustomSkillPath: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let addedAt: Date

    init(url: URL, displayName: String? = nil) {
        self.id = UUID()
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.addedAt = Date()
    }

    var storageKey: String {
        "custom-\(id.uuidString.prefix(8).lowercased())"
    }
}
