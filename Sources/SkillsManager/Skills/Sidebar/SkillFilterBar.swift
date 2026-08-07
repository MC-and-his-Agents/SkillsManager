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
                        Text(value.rawValue)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
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
                    .accessibilityLabel("Status: \(value.rawValue)")
                    .accessibilityValue(
                        filters.status == value ? "Selected" : "Not selected"
                    )
                    .accessibilityIdentifier("skills.filter.status.\(statusKey(for: value))")
                    .tint(filters.status == value ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 24)
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

    // MARK: - Source

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(SkillListSourceFilter.allCases) { value in
                    Button {
                        filters.source = value
                    } label: {
                        chipLabel(sourceShortText(for: value), icon: sourceIcon(for: value))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(filters.source == value ? .isSelected : [])
                    .accessibilityLabel("Source: \(value.displayName)")
                    .accessibilityValue(
                        filters.source == value ? "Selected" : "Not selected"
                    )
                    .accessibilityIdentifier("skills.filter.source.\(sourceKey(for: value))")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 22)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.filter.source")
    }

    private func sourceShortText(for value: SkillListSourceFilter) -> String {
        guard case .source(let source) = value else { return "All" }
        switch source {
        case .local: return "Local"
        case .repository: return "Repo"
        case .clawHub: return "ClawHub"
        case .skillsSh: return "skills.sh"
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
                        chipLabel(agentShortText(for: value), icon: nil)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(filters.agent == value ? .isSelected : [])
                    .accessibilityLabel("Agent: \(value.displayName)")
                    .accessibilityValue(
                        filters.agent == value ? "Selected" : "Not selected"
                    )
                    .accessibilityIdentifier("skills.filter.agent.\(agentKey(for: value))")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 22)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.filter.agent")
    }

    private func agentShortText(for value: SkillListAgentFilter) -> String {
        guard case .agent(let platform) = value else { return "All" }
        switch platform {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .opencode: return "OpenCode"
        case .copilot: return "Copilot"
        }
    }

    private func agentKey(for value: SkillListAgentFilter) -> String {
        guard case .agent(let platform) = value else { return "all" }
        return platform.storageKey
    }

    // MARK: - Shared

    private func chipLabel(_ text: String, icon: String?) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
            }
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.secondary.opacity(0.14))
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
        .help(collapsed ? "Show filters" : "Hide filters")
        .accessibilityLabel(collapsed ? "Show filters" : "Hide filters")
        .accessibilityIdentifier("skills.filter.collapse")
    }

    private var summaryLine: some View {
        HStack(spacing: 6) {
            Text(summaryText)
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
        .accessibilityLabel("Active filters: \(summaryText)")
        .accessibilityIdentifier("skills.filter.summary")
    }

    private var summaryText: String {
        if !filters.isActive { return "All Skills" }
        return [filters.status.rawValue, filters.source.displayName, filters.agent.displayName]
            .filter { $0 != "All Statuses" && $0 != "All Sources" && $0 != "All Agents" }
            .joined(separator: " · ")
    }

    // MARK: - Focus

    func focusFilters() {
        collapsed = false
        statusFocused = true
    }
}
