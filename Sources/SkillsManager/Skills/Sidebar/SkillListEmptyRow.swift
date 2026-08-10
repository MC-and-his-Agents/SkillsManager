import SwiftUI

/// Sidebar 列表内的统一空/错误状态行（#185）。
///
/// 视觉对齐 `ContentUnavailableView`（图标 + 标题 + 副标题），
/// 供本地/ClawHub/skills.sh/Repository 各通道复用；可选操作按钮
/// （如 Retry）保持交互。
struct SkillListEmptyRow: View {
    let title: String
    var message: String? = nil
    var icon: String = "tray"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var actionAccessibilityLabel: String? = nil

    init(
        title: String,
        message: String? = nil,
        icon: String = "tray",
        actionTitle: String? = nil,
        actionAccessibilityLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.actionTitle = actionTitle
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.action = action
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(localized(title))
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(localized(actionTitle), action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                    .accessibilityLabel(localized(actionAccessibilityLabel ?? actionTitle))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: action == nil ? .combine : .contain)
        .accessibilityLabel(
            [localized(title), message].compactMap { $0 }.joined(separator: ", ")
        )
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
