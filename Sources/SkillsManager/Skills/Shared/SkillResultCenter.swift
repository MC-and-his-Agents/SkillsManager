import Foundation
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
        let id = UUID()
        let skillID: String
        let text: String
        let systemImage: String
        let tint: Color
    }

    private(set) var current: Entry?
    private let autoDismissDelay: Duration
    private var autoDismissTask: Task<Void, Never>?

    init(autoDismissDelay: Duration = .seconds(20)) {
        self.autoDismissDelay = autoDismissDelay
    }

    func publish(_ entry: Entry) {
        current = entry
        autoDismissTask?.cancel()
        let delay = autoDismissDelay
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss(entryID: entry.id)
        }
    }

    func dismiss(entryID: UUID) {
        guard current?.id == entryID else { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        current = nil
    }

    var visible: Entry? { current }
}
