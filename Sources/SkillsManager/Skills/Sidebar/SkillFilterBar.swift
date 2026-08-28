import SwiftUI

/// Sidebar 内可见筛选区：Status 分段 + Source chips + Agent chips。
///
/// 紧凑三行布局、可折叠；折叠时显示当前激活值摘要。筛选激活时控件高亮。
/// 快捷键：⇧⌘F 展开并聚焦筛选区，⌘1-4 切换 Status。
struct SkillFilterBar: View {
    @Binding var filters: SkillListFilters

    @State private var collapsed = false
    @FocusState private var statusFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusSegment
                Spacer()
                collapseButton
            }

            if collapsed {
                summaryLine
            } else {
                sourceChips
                agentChips
            }

            focusShortcutButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.filter.bar")
    }

    /// ⇧⌘F 展开并聚焦筛选区；零尺寸按钮仅承载快捷键。
    private var focusShortcutButton: some View {
        Button {
            focusFilters()
        } label: {
            EmptyView()
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .accessibilityHidden(true)
    }

    // MARK: - Status

    private var statusSegment: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(SkillListStatusFilter.allCases) { value in
                    Button {
                        filters.status = value
                    } label: {
                        Text(verbatim: statusText(value))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    filters.status == value
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(statusShortcut(for: value))
                    .focused($statusFocused)
                    .accessibilityAddTraits(filters.status == value ? .isSelected : [])
                    .accessibilityLabel(Text(
                        String(
                            localized: LocalizedStringResource(
            "Status: \(statusText(value))",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                    ))
                    .accessibilityValue(
                        Text(
                            filters.status == value ? "Selected" : "Not selected",
                            bundle: SkillsManagerLocalizationResources.bundle
                        )
                    )
                    .accessibilityIdentifier("skills.filter.status.\(statusKey(for: value))")
                    .tint(filters.status == value ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.filter.status")
    }

    private func statusShortcut(for value: SkillListStatusFilter) -> KeyEquivalent {
        switch value {
        case .all: KeyEquivalent("1")
        case .managed: KeyEquivalent("2")
        case .needsImport: KeyEquivalent("3")
        case .available: KeyEquivalent("4")
        }
    }

    private func statusKey(for value: SkillListStatusFilter) -> String {
        switch value {
        case .all: "all"
        case .managed: "managed"
        case .needsImport: "needs-import"
        case .available: "available"
        }
    }

    private func statusText(_ value: SkillListStatusFilter) -> String {
        switch value {
        case .all: String(localized: "All Statuses", bundle: SkillsManagerLocalizationResources.bundle)
        case .managed: String(localized: "Managed", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsImport: String(localized: "Needs Import", bundle: SkillsManagerLocalizationResources.bundle)
        case .available: String(localized: "Available", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    // MARK: - Source

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(SkillListSourceFilter.allCases) { value in
                    Button {
                        filters.source = value
                    } label: {
                        chipLabel(
                            sourceShortText(for: value),
                            icon: sourceIcon(for: value),
                            isSelected: filters.source == value
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(filters.source == value ? .isSelected : [])
                    .accessibilityLabel(Text(
                        String(
                            localized: LocalizedStringResource(
            "Source: \(sourceText(value))",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                    ))
                    .accessibilityValue(
                        Text(
                            filters.source == value ? "Selected" : "Not selected",
                            bundle: SkillsManagerLocalizationResources.bundle
                        )
                    )
                    .accessibilityIdentifier("skills.filter.source.\(sourceKey(for: value))")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.filter.source")
    }

    private func sourceShortText(for value: SkillListSourceFilter) -> String {
        guard case .source(let source) = value else {
            return String(localized: "All", bundle: SkillsManagerLocalizationResources.bundle)
        }
        switch source {
        case .local: return String(localized: "Local", bundle: SkillsManagerLocalizationResources.bundle)
        case .repository: return String(localized: "Repo", bundle: SkillsManagerLocalizationResources.bundle)
        case .clawHub: return String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
        case .skillsSh: return String(localized: "skills.sh", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func sourceText(_ value: SkillListSourceFilter) -> String {
        switch value {
        case .all: String(localized: "All Sources", bundle: SkillsManagerLocalizationResources.bundle)
        case .source(let source):
            switch source {
            case .local: String(localized: "Local", bundle: SkillsManagerLocalizationResources.bundle)
            case .repository: String(localized: "Repository", bundle: SkillsManagerLocalizationResources.bundle)
            case .clawHub: String(localized: "ClawHub", bundle: SkillsManagerLocalizationResources.bundle)
            case .skillsSh: String(localized: "skills.sh", bundle: SkillsManagerLocalizationResources.bundle)
            }
        }
    }

    private func sourceIcon(for value: SkillListSourceFilter) -> String? {
        guard case .source(let source) = value else { return nil }
        return source.systemImage
    }

    private func sourceKey(for value: SkillListSourceFilter) -> String {
        guard case .source(let source) = value else { return "all" }
        switch source {
        case .local: return "local"
        case .repository: return "repository"
        case .clawHub: return "clawhub"
        case .skillsSh: return "skills-sh"
        }
    }

    // MARK: - Agent

    private var agentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(SkillListAgentFilter.allCases) { value in
                    Button {
                        filters.agent = value
                    } label: {
                        chipLabel(
                            agentShortText(for: value),
                            icon: nil,
                            isSelected: filters.agent == value
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(filters.agent == value ? .isSelected : [])
                    .accessibilityLabel(Text(
                        String(
                            localized: LocalizedStringResource(
            "Agent: \(agentText(value))",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
                    ))
                    .accessibilityValue(
                        Text(
                            filters.agent == value ? "Selected" : "Not selected",
                            bundle: SkillsManagerLocalizationResources.bundle
                        )
                    )
                    .accessibilityIdentifier("skills.filter.agent.\(agentKey(for: value))")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.filter.agent")
    }

    private func agentShortText(for value: SkillListAgentFilter) -> String {
        guard case .agent(let platform) = value else {
            return String(localized: "All", bundle: SkillsManagerLocalizationResources.bundle)
        }
        switch platform {
        case .codex: return String(localized: "Codex", bundle: SkillsManagerLocalizationResources.bundle)
        case .claude: return String(localized: "Claude", bundle: SkillsManagerLocalizationResources.bundle)
        case .opencode: return String(localized: "OpenCode", bundle: SkillsManagerLocalizationResources.bundle)
        case .copilot: return String(localized: "Copilot", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func agentText(_ value: SkillListAgentFilter) -> String {
        switch value {
        case .all: String(localized: "All Agents", bundle: SkillsManagerLocalizationResources.bundle)
        case .agent(let platform):
            switch platform {
            case .codex: String(localized: "Codex", bundle: SkillsManagerLocalizationResources.bundle)
            case .claude: String(localized: "Claude Code", bundle: SkillsManagerLocalizationResources.bundle)
            case .opencode: String(localized: "OpenCode", bundle: SkillsManagerLocalizationResources.bundle)
            case .copilot: String(localized: "GitHub Copilot", bundle: SkillsManagerLocalizationResources.bundle)
            }
        }
    }

    private func agentKey(for value: SkillListAgentFilter) -> String {
        guard case .agent(let platform) = value else { return "all" }
        return platform.storageKey
    }

    // MARK: - Shared

    private func chipLabel(_ text: String, icon: String?, isSelected: Bool) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
            }
            Text(verbatim: text)
                .font(.caption)
        }
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color.secondary.opacity(0.14)
            )
        )
        .contentShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                isSelected ? Color.accentColor.opacity(0.45) : Color.clear,
                lineWidth: 1
            )
        )
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: collapsed
                ? "chevron.down"
                : "chevron.up")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(Text(verbatim: collapseLabelText))
        .accessibilityLabel(Text(verbatim: collapseLabelText))
        .accessibilityIdentifier("skills.filter.collapse")
    }

    private var collapseLabelText: String {
        if collapsed {
            return String(localized: "Show filters", bundle: SkillsManagerLocalizationResources.bundle)
        }
        return String(localized: "Hide filters", bundle: SkillsManagerLocalizationResources.bundle)
    }

    private var activeFilterCount: Int {
        [filters.status != .all, filters.source != .all, filters.agent != .all]
            .filter { $0 }.count
    }

    private var summaryLine: some View {
        HStack(spacing: 6) {
            if filters.isActive {
                Text(String(
                    localized: LocalizedStringResource(
                "\(activeFilterCount) active",
                bundle: SkillsManagerLocalizationResources.bundle
            )))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.22)))
                    .foregroundStyle(Color.accentColor)
            }
            Text(verbatim: summaryText)
                .font(.caption)
                .foregroundStyle(filters.isActive ? .primary : .secondary)
            if filters.isActive {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            String(
                localized: LocalizedStringResource(
            "Active filters: \(summaryText)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
        ))
        .accessibilityIdentifier("skills.filter.summary")
    }

    private var summaryText: String {
        if !filters.isActive {
            return String(localized: "All Skills", bundle: SkillsManagerLocalizationResources.bundle)
        }
        let components = [
            (statusText(filters.status), filters.status != .all),
            (sourceText(filters.source), filters.source != .all),
            (agentText(filters.agent), filters.agent != .all),
        ]
        return components
            .filter(\.1)
            .map(\.0)
            .joined(separator: " · ")
    }

    // MARK: - Focus

    func focusFilters() {
        collapsed = false
        statusFocused = true
    }
}
