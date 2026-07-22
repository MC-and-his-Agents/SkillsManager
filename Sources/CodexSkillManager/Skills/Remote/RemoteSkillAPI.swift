import Foundation

struct RemoteSkillAPI {
    struct SkillListResponse: Decodable {
        let items: [SkillListItem]
    }

    struct SkillListItem: Decodable {
        let slug: String
        let displayName: String
        let summary: String?
        let updatedAt: TimeInterval
        let latestVersion: LatestVersion?
        let stats: Stats?
    }

    struct Stats: Decodable {
        let comments: Int?
        let downloads: Int?
        let installsAllTime: Int?
        let installsCurrent: Int?
        let stars: Int?
        let versions: Int?
    }

    struct LatestVersion: Decodable {
        let version: String
        let createdAt: TimeInterval
        let changelog: String
    }

    struct SearchResponse: Decodable {
        let results: [SearchResult]
    }

    struct SearchResult: Decodable {
        let slug: String?
        let displayName: String?
        let summary: String?
        let version: String?
        let updatedAt: TimeInterval?
    }

    struct SkillDetailResponse: Decodable {
        let owner: Owner?
    }

    struct SkillResponse: Decodable {
        let skill: SkillSummary?
        let latestVersion: LatestVersion?
        let owner: Owner?
    }

    struct SkillSummary: Decodable {
        let slug: String
        let displayName: String
        let summary: String?
        let createdAt: TimeInterval
        let updatedAt: TimeInterval
    }

    struct Owner: Decodable {
        let handle: String?
        let displayName: String?
        let image: String?
    }
}
