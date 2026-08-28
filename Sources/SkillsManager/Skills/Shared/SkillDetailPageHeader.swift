import SwiftUI

/// 详情页统一骨架（#244，Epic B5）。
///
/// 远程类详情（ClawHub / skills.sh / Repository 候选）共用本组件：
/// 大标题 + 可选副标题 + tag 行 + 主操作行，视觉节奏一致。
/// managed / discovery 详情使用 SkillDetailActionBar 骨架
/// （状态徽章 + 来源 + Agent chips + 更新/删除），两者构成应用的两类
/// 详情页面形态。
struct SkillDetailPageHeader<TagContent: View, ActionContent: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var tags: () -> TagContent
    @ViewBuilder var actions: () -> ActionContent

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder tags: @escaping () -> TagContent,
        @ViewBuilder actions: @escaping () -> ActionContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tags = tags
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.largeTitle.bold())
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                tags()
            }
            HStack(spacing: 12) {
                actions()
            }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
