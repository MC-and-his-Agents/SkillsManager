import Foundation
import Observation

@MainActor
@Observable final class RemoteSkillStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum DetailState: Equatable {
        case idle
        case loading
        case loaded
        case cachedRefreshing
        case failed(String)
    }

    var latestSkills: [RemoteSkill] = []
    var searchResults: [RemoteSkill] = []
    var latestState: LoadState = .idle
    var searchState: LoadState = .idle
    var selectedSkillID: RemoteSkill.ID?
    var detailMarkdown: String = ""
    var detailState: DetailState = .idle
    var detailOwner: RemoteSkillOwner?

    private let apiClient: RemoteSkillClient
    private let fileWorker = SkillFileWorker()
    private let detailCache = RemoteSkillDetailCache.shared
    private var activeSearchToken = 0
    private var activeSearchQuery = ""

    init(client: RemoteSkillClient) {
        self.apiClient = client
    }

    var client: RemoteSkillClient {
        apiClient
    }

    var selectedSkill: RemoteSkill? {
        (searchResults + latestSkills).first { $0.id == selectedSkillID }
    }

    func loadLatest(limit: Int = 12) async {
        latestState = .loading
        do {
            latestSkills = try await apiClient.fetchLatest(limit)
            latestState = .loaded
        } catch {
            latestState = .failed(error.localizedDescription)
        }
    }

    func search(query: String, limit: Int = 20) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchQuery = trimmed
        activeSearchToken += 1
        let token = activeSearchToken
        guard !trimmed.isEmpty else {
            searchResults = []
            searchState = .idle
            return
        }

        searchState = .loading
        do {
            let results = try await apiClient.search(trimmed, limit)
            guard token == activeSearchToken, activeSearchQuery == trimmed else {
                return
            }
            searchResults = results
            searchState = .loaded
        } catch {
            guard token == activeSearchToken else { return }
            searchState = .failed(error.localizedDescription)
        }
    }

    func loadSelectedSkill() async {
        guard let skill = selectedSkill else {
            detailState = .idle
            detailMarkdown = ""
            detailOwner = nil
            return
        }

        // Check NSCache first (application-level cache)
        if let cached = detailCache.get(slug: skill.slug, version: skill.latestVersion) {
            detailMarkdown = cached.markdown
            detailOwner = cached.owner
            detailState = .cachedRefreshing
        } else {
            detailState = .loading
            detailMarkdown = ""
            detailOwner = nil
        }

        // Fetch from network (URLCache may provide HTTP-level caching)
        do {
            let owner = try await apiClient.fetchDetail(skill.slug)
            let zipURL = try await apiClient.download(skill.slug, skill.latestVersion)
            let markdown = stripFrontmatter(from: try await fileWorker.loadRawMarkdown(from: zipURL))

            guard skill.id == selectedSkillID else { return }

            // Update NSCache with fresh data
            detailCache.set(
                CachedSkillDetail(markdown: markdown, owner: owner),
                slug: skill.slug,
                version: skill.latestVersion
            )

            detailOwner = owner
            detailMarkdown = markdown
            detailState = .loaded
        } catch {
            guard skill.id == selectedSkillID else { return }

            // If we had cached content, silently keep showing it
            if detailState == .cachedRefreshing {
                detailState = .loaded
            } else {
                detailState = .failed(error.localizedDescription)
                detailMarkdown = ""
            }
        }
    }

}
