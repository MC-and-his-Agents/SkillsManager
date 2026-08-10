import SwiftUI

/// 详情页顶部结果 banner（#185）：安装/更新/删除/分发结果统一呈现。
/// 成功绿、失败橙；自动消退或手动关闭。复用既有 banner 视觉模式。
struct SkillResultBanner: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(tint)
            Spacer(minLength: 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Result: \(message)", bundle: .module))
    }
}

/// 详情页反馈聚合：删除/分发/更新/导入的结果消息统一为一个 banner 槽位。
///
/// 优先级：失败（橙）> 成功（绿）；同一时刻只显示一条；首次发布时结果写入
/// `SkillResultCenter`（跨详情视图重建持久），自动消退（20s）后消失；
/// 切换 Skill 时按 `skillID` 匹配不再显示旧结果。
struct SkillDetailFeedbackBanner: View {
    @Environment(SkillDistributionViewModel.self) private var distributionModel
    @Environment(SkillUpdateCheckViewModel.self) private var updateCheckModel
    @Environment(SkillLifecycleViewModel.self) private var lifecycleModel
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(SkillResultCenter.self) private var resultCenter

    /// 当前详情视图对应的 Skill 身份（managed 用 `Skill.id`，discovered 用 item id）。
    let skillID: String
    /// 视图本地错误通道（如 discovered 详情预览/导入流程错误）。
    var extraErrorMessage: String? = nil

    private struct Feedback: Equatable {
        let text: String
        let systemImage: String
        let tint: Color
    }

    private var feedback: Feedback? {
        if let problem = lifecycleModel.problem {
            return Feedback(
                text: problem.message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if let problem = distributionModel.problem {
            return Feedback(
                text: problem.message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if let problem = updateCheckModel.updateProblem {
            return Feedback(
                text: problem.localizedDescription,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if let message = discoveryModel.importErrorMessage {
            return Feedback(
                text: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if let message = extraErrorMessage {
            return Feedback(
                text: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if let result = updateCheckModel.updateResult {
            return Feedback(
                text: result.displayName,
                systemImage: result.systemImage,
                tint: result.requiresAttention ? .orange : .green
            )
        }
        if let message = lifecycleModel.successMessage {
            return Feedback(text: message, systemImage: "checkmark.circle.fill", tint: .green)
        }
        if let message = distributionModel.successMessage {
            return Feedback(text: message, systemImage: "checkmark.circle.fill", tint: .green)
        }
        if let message = discoveryModel.importResultMessage {
            return Feedback(text: message, systemImage: "checkmark.circle.fill", tint: .green)
        }
        return nil
    }

    var body: some View {
        Group {
            if let entry = resultCenter.visible, entry.skillID == skillID {
                SkillResultBanner(
                    message: entry.text,
                    systemImage: entry.systemImage,
                    tint: entry.tint
                )
                .transition(.opacity)
            }
        }
        .onChange(of: feedback) { _, newValue in
            guard let newValue else { return }
            resultCenter.publish(SkillResultCenter.Entry(
                skillID: skillID,
                text: newValue.text,
                systemImage: newValue.systemImage,
                tint: newValue.tint
            ))
        }
    }
}
