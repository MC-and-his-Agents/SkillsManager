import Foundation
import Observation

/// 行内更新徽章的内存级缓存（#185）。
///
/// 仅对 ClawHub 来源 Skill 启用：行出现时惰性检查一次最新版本（单请求，
/// 零批量网络），失败静默（不显示徽章、不缓存失败，下次行出现可重试）。
/// 缓存生命周期与当前 Skill 列表一致：列表刷新时 `invalidateAll` 触发
/// 可见行重新检查；详情更新检查完成时 `backfill` 回填避免重复请求。
@MainActor
@Observable final class SkillUpdateBadgeStore {
    enum Badge: Equatable {
        case updateAvailable(version: String)
        case needsAttention
        case upToDate
    }

    private(set) var badges: [Skill.ID: Badge] = [:]
    private(set) var refreshGeneration: UInt64 = 0
    private var inFlight: [Skill.ID: UUID] = [:]
    private let remote: RemoteSkillClient

    init(remote: RemoteSkillClient) {
        self.remote = remote
    }

    /// 行徽章；`needsRepair` 不需要网络直接判定。
    func badge(for skill: Skill) -> Badge? {
        if skill.managedStatus == .needsRepair { return .needsAttention }
        return badges[skill.id]
    }

    /// 行出现时调用：仅在 ClawHub 来源且状态未确定时发起单次轻量检查。
    /// 失败静默且不缓存，保持无徽章。
    func checkIfNeeded(for skill: Skill) async {
        guard badge(for: skill) == nil else { return }
        guard let slug = skill.clawdhubSlug,
              let installed = skill.clawdhubVersion else {
            badges[skill.id] = .upToDate
            return
        }
        guard inFlight[skill.id] == nil else { return }
        let generation = refreshGeneration
        let token = UUID()
        inFlight[skill.id] = token
        defer {
            if inFlight[skill.id] == token {
                inFlight[skill.id] = nil
            }
        }
        guard let latest = try? await remote.fetchLatestVersion(slug),
              !latest.isEmpty else {
            return
        }
        guard generation == refreshGeneration,
              inFlight[skill.id] == token else {
            return
        }
        badges[skill.id] = SkillVersionComparison.isNewer(latest, than: installed)
            ? .updateAvailable(version: latest)
            : .upToDate
    }

    /// 详情更新检查结果回填，避免重复网络请求。
    func backfill(_ skill: Skill, latestVersion: String?, generation: UInt64) {
        guard generation == refreshGeneration,
              let latest = latestVersion,
              !latest.isEmpty,
              let installed = skill.clawdhubVersion else { return }
        inFlight[skill.id] = nil
        badges[skill.id] = SkillVersionComparison.isNewer(latest, than: installed)
            ? .updateAvailable(version: latest)
            : .upToDate
    }

    func invalidate(skillID: Skill.ID) {
        badges[skillID] = nil
        inFlight[skillID] = nil
    }

    /// 列表刷新时调用：清空缓存并推进 generation，让可见行重新检查。
    func invalidateAll() {
        badges = [:]
        inFlight = [:]
        refreshGeneration &+= 1
    }
}
