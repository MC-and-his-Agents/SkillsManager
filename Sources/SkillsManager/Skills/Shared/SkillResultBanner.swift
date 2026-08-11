import SwiftUI

/// 详情页顶部结果 banner（#185）：安装/更新/删除/分发结果统一呈现。
/// 成功绿、失败橙；自动消退或手动关闭。复用既有 banner 视觉模式。
struct SkillResultBanner: View {
    let message: String
    let systemImage: String
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: systemImage)
            }
                .foregroundStyle(tint)
                .accessibilityLabel(Text(String(
                    localized: LocalizedStringResource(
                        "Result: \(message)",
                        bundle: SkillsManagerLocalizationResources.bundle
                    )
                )))
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("skills.result.close")
            .accessibilityLabel(Text("Close", bundle: SkillsManagerLocalizationResources.bundle))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

struct SkillResultCenterBanner: View {
    @Environment(SkillResultCenter.self) private var resultCenter

    let subject: SkillResultCenter.Subject

    var body: some View {
        Group {
            if let entry = resultCenter.visible, entry.subject == subject {
                SkillResultBanner(
                    message: entry.text,
                    systemImage: entry.systemImage,
                    tint: entry.tint,
                    onDismiss: { resultCenter.dismiss(entryID: entry.id) }
                )
                .transition(.opacity)
            }
        }
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

    let subject: SkillResultCenter.Subject
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
                text: localizedManagedSkillUpdateExecutionProblem(problem),
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
        SkillResultCenterBanner(subject: subject)
        .onChange(of: feedback) { _, newValue in
            guard let newValue else { return }
            resultCenter.publish(SkillResultCenter.Entry(
                subject: subject,
                text: newValue.text,
                systemImage: newValue.systemImage,
                tint: newValue.tint
            ))
        }
    }
}

extension SkillResultCenter {
    func publishInstallResult(_ result: ManagedLocalImportResult, subject: Subject) {
        let presentation = managedInstallResultPresentation(result)
        publish(Entry(
            subject: subject,
            text: presentation.message,
            systemImage: presentation.systemImage,
            tint: result.status.requiresAttention ? .orange : .green
        ))
    }

    func publishInstallFailure(_ message: String, subject: Subject) {
        publish(Entry(
            subject: subject,
            text: message,
            systemImage: "exclamationmark.triangle.fill",
            tint: .orange
        ))
    }
}

private extension ManagedLocalImportResultStatus {
    var requiresAttention: Bool {
        switch self {
        case .distributed, .noDistributionChanges, .alreadyManaged, .updated:
            false
        case .managedUndistributed, .managedDistributionIndeterminate,
             .managementIndeterminate, .updateRequired,
             .updatedDistributionNeedsAttention, .updateIndeterminate:
            true
        }
    }
}
