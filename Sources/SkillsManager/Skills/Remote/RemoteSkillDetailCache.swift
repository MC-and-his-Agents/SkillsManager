import Foundation

/// Cached detail data for a remote skill
struct CachedSkillDetail {
    let markdown: String
    let owner: RemoteSkillOwner?
}

/// Memory cache for remote skill details using NSCache
/// Provides automatic memory pressure eviction
final class RemoteSkillDetailCache: @unchecked Sendable {
    static let shared = RemoteSkillDetailCache()

    private let cache = NSCache<NSString, CacheEntry>()

    /// Wrapper class since NSCache requires reference types
    private final class CacheEntry {
        let detail: CachedSkillDetail
        init(_ detail: CachedSkillDetail) { self.detail = detail }
    }

    private init() {
        cache.countLimit = 50
    }

    func get(slug: String, version: String?) -> CachedSkillDetail? {
        let key = cacheKey(slug: slug, version: version)
        return cache.object(forKey: key)?.detail
    }

    func set(_ detail: CachedSkillDetail, slug: String, version: String?) {
        let key = cacheKey(slug: slug, version: version)
        cache.setObject(CacheEntry(detail), forKey: key)
    }

    private func cacheKey(slug: String, version: String?) -> NSString {
        "\(slug):\(version ?? "latest")" as NSString
    }
}
