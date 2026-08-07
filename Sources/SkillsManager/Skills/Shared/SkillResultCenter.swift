import Observation
import SwiftUI

/// 详情操作结果的 App 级收口（#185）。
///
/// 操作完成后的模型刷新（`loadSkills` 重置详情视图）会清除各模型的
/// feedback 消息；本中心在首次发布时捕获结果并保留至自动消退或
/// 新结果覆盖，banner 组件按 skillID 匹配显示，跨视图重建不丢失。
@MainActor
@Observable final class SkillResultCenter {
    struct Entry: Equatable {
        let skillID: String
        let text: String
        let systemImage: String
        let tint: Color
    }

    private(set) var current: Entry?
    private var dismissed: Set<String> = []

    func publish(_ entry: Entry) {
        current = entry
        Task {
            try? await Task.sleep(for: .seconds(20))
            dismissed.insert(entry.text)
        }
    }

    /// 当前可见结果（未消退且未被手动关闭）。
    var visible: Entry? {
        guard let current, !dismissed.contains(current.text) else { return nil }
        return current
    }
}
