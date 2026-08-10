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
                    ? "Needs Attention"
                    : "Managed",
                systemImage: skill.managedStatus == .needsRepair
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.seal.fill",
                tint: skill.managedStatus == .needsRepair ? .orange : .green,
                accessibilityValue: skill.managedStatus == .needsRepair
                    ? "Managed Skill needs repair"
                    : "Managed and in sync"
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
                title: "Managed",
                systemImage: "checkmark.seal.fill",
                tint: .green,
                accessibilityValue: "Matches an existing managed Skill"
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
            Text(localized(badge.title))
        }
        .font(.callout.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Status: \(localized(badge.title))", bundle: .module))
        .accessibilityValue(Text(verbatim: localized(badge.accessibilityValue)))
        .accessibilityIdentifier("skills.detail.badge")
    }

    private var sourceIcons: some View {
        HStack(spacing: 8) {
            ForEach(sourceLabels) { label in
                Image(systemName: label.systemImage)
                    .help(Text(verbatim: localized(label.text)))
                    .accessibilityLabel(Text(
                        "Source: \(localized(label.text))",
                        bundle: .module
                    ))
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
                        Text(localized(row.platform.rawValue))
                    }
                }
                .toggleStyle(.button)
                .disabled(distributionModel.isApplying)
                .accessibilityLabel(Text("\(localized(row.platform.rawValue)) distribution", bundle: .module))
                .accessibilityValue(
                    Text(
                        row.isSelected
                            ? "Selected; currently \(localized(row.isCurrentlyEnabled ? "enabled" : "disabled"))"
                            : "Not selected; currently \(localized(row.isCurrentlyEnabled ? "enabled" : "disabled"))",
                        bundle: .module
                    )
                )
                .accessibilityHint(Text("Target: \(row.locator)", bundle: .module))
                .accessibilityIdentifier("skills.detail.agent.\(row.platform.storageKey)")
            }
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        if updateCheckModel.isChecking
            || updateCheckModel.isPreparingUpdate
            || updateCheckModel.isUpdating {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Checking for updates", bundle: .module))
        } else if let snapshot = loadedSnapshot, snapshot.hasExecutableRemoteUpdate {
            Button {
                Task { await updateCheckModel.prepareUpdate(snapshot) }
            } label: {
            Label {
                Text("Review Update", bundle: .module)
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
            }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .accessibilityIdentifier("skills.detail.update")
            .accessibilityValue(Text("Update available", bundle: .module))
            .accessibilityHint(Text(
                "Reviews the remote update before anything is written.",
                bundle: .module
            ))
        } else {
            Button {
                Task { await updateCheckModel.checkCurrent() }
            } label: {
                Label {
                    Text("Check for Updates", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(loadedSnapshot == nil || updateCheckModel.isChecking)
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .accessibilityIdentifier("skills.detail.update")
            .accessibilityValue(Text(
                loadedSnapshot == nil ? "Update check unavailable" : "No update available",
                bundle: .module
            ))
        }
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
                Text("Batch Updates", bundle: .module)
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
        }
        .disabled(batchUpdatesDisabled)
        .accessibilityIdentifier("skills.detail.batch-updates")
        .accessibilityValue(Text(verbatim: localized(batchUpdateHelp)))
        .accessibilityHint(Text(verbatim: localized(batchUpdateHelp)))
    }

    private var batchUpdatesDisabled: Bool {
        store.skills.isEmpty
            || libraryRuntime.readiness != .ready
            || batchUpdateModel.operationActive
    }

    private var batchUpdateHelp: String {
        if libraryRuntime.readiness != .ready {
            return "Batch updates are unavailable until the managed library is ready."
        }
        if store.skills.isEmpty {
            return "Import a managed Skill before checking for batch updates."
        }
        if batchUpdateModel.operationActive {
            return "A batch update is already running."
        }
        return "Check all managed Skills for updates."
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
                Text("Show in Finder", bundle: .module)
            } icon: {
                Image(systemName: "folder")
            }
        }
        .disabled(finderURL == nil)
        .accessibilityIdentifier("skills.detail.finder")
        .help(Text("Opens the Skill folder in Finder", bundle: .module))
    }

    private var fullSettingsButton: some View {
        Button(action: onFullSettings) {
            Label {
                Text("Full Settings…", bundle: .module)
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
        }
        .accessibilityIdentifier("skills.detail.full-settings")
        .help(Text("Scrolls to the complete distribution editor", bundle: .module))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            lifecycleModel.prepareDeletion()
        } label: {
            Label {
                Text("Delete", bundle: .module)
            } icon: {
                Image(systemName: "trash")
            }
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!canDelete)
        .accessibilityIdentifier("skills.detail.delete")
        .accessibilityHint(Text(
            "Backs up the Skill, removes managed Agent links, and deletes the managed Skill.",
            bundle: .module
        ))
    }

    private var canDelete: Bool {
        guard !lifecycleModel.isMutating,
              case .ready(let preview) = lifecycleModel.deletionState else {
            return false
        }
        return preview.status == .ready && preview.token != nil
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
