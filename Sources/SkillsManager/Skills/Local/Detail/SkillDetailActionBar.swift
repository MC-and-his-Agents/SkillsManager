import AppKit
import SwiftUI

/// 详情页顶部固定操作条（managed Skill）。
///
/// 将启用/更新/删除/打开位置等日常操作从滚动尾部提升到不随滚动的一眼可见区域。
/// Agent chips 直接复用 `SkillDistributionViewModel` 的草稿语义：切换只修改
/// draft，真正生效仍走既有预览/应用流程（`hasUnappliedDraft` 提示可见）。
struct SkillDetailActionBar: View {
    let skill: Skill
    let onFullSettings: () -> Void

    var body: some View {
        SkillDetailActionBarContent(
            badge: SkillActionBarBadge(
                title: skill.managedStatus == .needsRepair
                    ? String(localized: "Needs Repair", bundle: SkillsManagerLocalizationResources.bundle)
                    : String(localized: "Managed", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: skill.managedStatus == .needsRepair
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.seal.fill",
                tint: skill.managedStatus == .needsRepair ? SkillStatusPalette.warning : SkillStatusPalette.healthy,
                accessibilityValue: skill.managedStatus == .needsRepair
                    ? String(localized: "Managed Skill needs repair", bundle: SkillsManagerLocalizationResources.bundle)
                    : String(localized: "Managed and in sync", bundle: SkillsManagerLocalizationResources.bundle)
            ),
            sourceLabels: skill.listOrigin.labels,
            finderURL: skill.folderURL,
            onFullSettings: onFullSettings
        )
    }
}

/// 详情页顶部固定操作条（discovered 匹配项）。
///
/// 仅当观察状态为 managed 且已匹配到 Skill ID 时由详情视图呈现；
/// 复用与 managed 变体完全相同的分发/更新/删除模型。
struct SkillDiscoveryActionBar: View {
    let item: SkillDiscoveryViewModel.Item
    let onFullSettings: () -> Void

    private var observation: SkillDiscoveryObservation { item.observation }

    var body: some View {
        SkillDetailActionBarContent(
            badge: SkillActionBarBadge(
                title: String(localized: "Managed", bundle: SkillsManagerLocalizationResources.bundle),
                systemImage: "checkmark.seal.fill",
                tint: SkillStatusPalette.healthy,
                accessibilityValue: String(localized: "Matches an existing managed Skill", bundle: SkillsManagerLocalizationResources.bundle)
            ),
            sourceLabels: observation.listOrigin.labels,
            finderURL: observation.displayURLs.first,
            onFullSettings: onFullSettings
        )
    }
}

private struct SkillActionBarBadge {
    let title: String
    let systemImage: String
    let tint: Color
    let accessibilityValue: String
}

/// 操作条共享内容：徽章 + 来源图标 + Agent chips + 更新/批量更新/完整设置/Finder/删除。
private struct SkillDetailActionBarContent: View {
    @Environment(SkillDistributionViewModel.self) private var distributionModel
    @Environment(SkillUpdateCheckViewModel.self) private var updateCheckModel
    @Environment(SkillLifecycleViewModel.self) private var lifecycleModel
    @Environment(SkillBatchUpdateViewModel.self) private var batchUpdateModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime
    @Environment(SkillStore.self) private var store

    let badge: SkillActionBarBadge
    let sourceLabels: [SkillListSourceLabel]
    let finderURL: URL?
    let onFullSettings: () -> Void

    @State private var showingBatchUpdates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                statusBadge
                sourceIcons
                Spacer()
                finderButton
                fullSettingsButton
                deleteButton
            }

            HStack(spacing: 8) {
                agentChips
                Spacer()
                updateButton
                batchUpdatesButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .sheet(isPresented: $showingBatchUpdates) {
            SkillBatchUpdateView().environment(batchUpdateModel)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: badge.systemImage)
                .foregroundStyle(badge.tint)
            Text(verbatim: badge.title)
        }
        .font(.callout.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(
            localized: LocalizedStringResource(
            "Status: \(badge.title)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))))
        .accessibilityValue(Text(verbatim: badge.accessibilityValue))
        .accessibilityIdentifier("skills.detail.badge")
    }

    private var sourceIcons: some View {
        HStack(spacing: 8) {
            ForEach(sourceLabels) { label in
                Image(systemName: label.systemImage)
                    .help(Text(verbatim: sourceText(label)))
                    .accessibilityLabel(Text(String(
                        localized: LocalizedStringResource(
            "Source: \(sourceText(label))",
            bundle: SkillsManagerLocalizationResources.bundle
        ))))
                    .accessibilityIdentifier("skills.detail.source.\(label.text)")
            }
        }
    }

    private var agentChips: some View {
        HStack(spacing: 6) {
            ForEach(distributionModel.agentRows) { row in
                Toggle(
                    isOn: Binding(
                        get: { row.isSelected },
                        set: { distributionModel.setAgent(row.platform, selected: $0) }
                    )
                ) {
                    HStack(spacing: 4) {
                        Image(systemName: row.isCurrentlyEnabled
                            ? "checkmark.circle.fill"
                            : "circle")
                        Text(verbatim: platformText(row.platform))
                    }
                }
                .toggleStyle(.button)
                .disabled(distributionModel.isApplying)
                .accessibilityLabel(Text(String(
                    localized: LocalizedStringResource(
            "\(platformText(row.platform)) distribution",
            bundle: SkillsManagerLocalizationResources.bundle
        ))))
                .accessibilityValue(
                    String(
                        localized: LocalizedStringResource(
            row.isSelected
                            ? "Selected; currently \(enabledText(row.isCurrentlyEnabled))"
                            : "Not selected; currently \(enabledText(row.isCurrentlyEnabled))",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                )
                .accessibilityHint(Text(String(
                    localized: LocalizedStringResource(
            "Target: \(row.locator)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))))
                .accessibilityIdentifier("skills.detail.agent.\(row.platform.storageKey)")
            }
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        if updateCheckModel.isChecking
            || updateCheckModel.isPreparingUpdate
            || updateCheckModel.isUpdating {
            // 检查/执行中保留按钮语义（禁用 + 进度 + 文案），不再退化为裸 ProgressView。
            Button {
                // 执行中不可重新触发；取消路径在确认 sheet 内。
            } label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(updateCheckModel.isUpdating
                        ? "Updating…"
                        : "Checking for updates…", bundle: SkillsManagerLocalizationResources.bundle)
                }
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .accessibilityIdentifier("skills.detail.update")
            .accessibilityLabel(Text(
                updateCheckModel.isUpdating ? "Updating Skill" : "Checking for updates",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        } else if let snapshot = loadedSnapshot, snapshot.hasExecutableRemoteUpdate {
            Button {
                Task { await updateCheckModel.prepareUpdate(snapshot) }
            } label: {
            Label {
                Text("Review Update", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
            }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .accessibilityIdentifier("skills.detail.update")
            .accessibilityValue(Text("Update available", bundle: SkillsManagerLocalizationResources.bundle))
            .accessibilityHint(Text(
                "Reviews the remote update before anything is written.",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        } else {
            Button {
                Task { await updateCheckModel.checkCurrent() }
            } label: {
                Label {
                    Text("Check for Updates", bundle: SkillsManagerLocalizationResources.bundle)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(!hasLoadedSkill || updateCheckModel.isChecking)
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .accessibilityIdentifier("skills.detail.update")
            .accessibilityValue(Text(
                hasLoadedSkill ? "No update available" : "Update check unavailable",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        }
    }

    /// ActionBar 是详情页唯一的更新检查入口；只要该 Skill 的更新状态已加载
    /// （即使从未检查过），即可发起检查。
    private var hasLoadedSkill: Bool {
        if case .loaded = updateCheckModel.loadState { return true }
        return false
    }

    private var loadedSnapshot: ManagedSkillUpdateCheckSnapshot? {
        guard case .loaded(let snapshot) = updateCheckModel.loadState else { return nil }
        return snapshot
    }

    private var batchUpdatesButton: some View {
        Button {
            configureBatchUpdates()
            showingBatchUpdates = true
        } label: {
            Label {
                Text("Batch Updates", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
        }
        .disabled(batchUpdatesDisabled)
        .accessibilityIdentifier("skills.detail.batch-updates")
        .accessibilityValue(Text(verbatim: batchUpdateHelp))
        .accessibilityHint(Text(verbatim: batchUpdateHelp))
    }

    private var batchUpdatesDisabled: Bool {
        store.skills.isEmpty
            || libraryRuntime.readiness != .ready
            || batchUpdateModel.operationActive
    }

    private var batchUpdateHelp: String {
        if libraryRuntime.readiness != .ready {
            return String(localized: "Batch updates are unavailable until the managed library is ready.", bundle: SkillsManagerLocalizationResources.bundle)
        }
        if store.skills.isEmpty {
            return String(localized: "Import a managed Skill before checking for batch updates.", bundle: SkillsManagerLocalizationResources.bundle)
        }
        if batchUpdateModel.operationActive {
            return String(localized: "A batch update is already running.", bundle: SkillsManagerLocalizationResources.bundle)
        }
        return String(localized: "Check all managed Skills for updates.", bundle: SkillsManagerLocalizationResources.bundle)
    }

    private func configureBatchUpdates() {
        batchUpdateModel.configure(store.skills.map {
            SkillBatchUpdateCatalogItem(
                skillID: $0.managedSkillID,
                displayName: $0.displayName
            )
        })
    }

    private var finderButton: some View {
        Button {
            guard let finderURL else { return }
            NSWorkspace.shared.open(finderURL)
        } label: {
            Label {
                Text("Show in Finder", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "folder")
            }
        }
        .disabled(finderURL == nil)
        .accessibilityIdentifier("skills.detail.finder")
        .help(Text("Opens the Skill folder in Finder", bundle: SkillsManagerLocalizationResources.bundle))
    }

    private var fullSettingsButton: some View {
        Button(action: onFullSettings) {
            Label {
                Text("Full Distribution Settings…", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
        }
        .accessibilityIdentifier("skills.detail.full-settings")
        .help(Text("Scrolls to the complete distribution editor", bundle: SkillsManagerLocalizationResources.bundle))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            lifecycleModel.prepareDeletion()
        } label: {
            Label {
                Text("Delete", bundle: SkillsManagerLocalizationResources.bundle)
            } icon: {
                Image(systemName: "trash")
            }
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!canDelete)
        .accessibilityIdentifier("skills.detail.delete")
        .accessibilityHint(Text(
            "Backs up the Skill, removes managed Agent links, and deletes the managed Skill.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }

    private var canDelete: Bool {
        guard !lifecycleModel.isMutating,
              case .ready(let preview) = lifecycleModel.deletionState else {
            return false
        }
        return preview.status == .ready && preview.token != nil
    }

    private func sourceText(_ label: SkillListSourceLabel) -> String {
        guard let source = label.knownSource else { return label.text }
        switch source {
        case .local:
            return String(localized: "Local", bundle: SkillsManagerLocalizationResources.bundle)
        case .repository:
            return String(localized: "Repository", bundle: SkillsManagerLocalizationResources.bundle)
        case .clawHub:
            return String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
        case .skillsSh:
            return String(localized: "skills.sh", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func platformText(_ platform: SkillPlatform) -> String {
        switch platform {
        case .codex:
            String(localized: "Codex", bundle: SkillsManagerLocalizationResources.bundle)
        case .claude:
            String(localized: "Claude Code", bundle: SkillsManagerLocalizationResources.bundle)
        case .opencode:
            String(localized: "OpenCode", bundle: SkillsManagerLocalizationResources.bundle)
        case .copilot:
            String(localized: "GitHub Copilot", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func enabledText(_ enabled: Bool) -> String {
        if enabled {
            return String(localized: "enabled", bundle: SkillsManagerLocalizationResources.bundle)
        }
        return String(localized: "disabled", bundle: SkillsManagerLocalizationResources.bundle)
    }
}
