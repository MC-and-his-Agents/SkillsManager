import SwiftUI

struct SkillDiscoverySidebarView: View {
    @Environment(SkillDiscoveryViewModel.self) private var model

    let items: [SkillDiscoveryViewModel.Item]
    @Binding var source: SkillSource

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedItemID) {
            SidebarHeaderView(
                skillCount: model.summary.discoveredCount,
                source: $source
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section("Scan summary") {
                summaryRows
            }

            stateContent
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh discovery", systemImage: "arrow.clockwise")
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(model.isRefreshing || isRuntimeBlocked)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(
                    model.isRefreshing ? "Refreshing discovery" : "Refresh discovery"
                )
            }
        }
    }

    @ViewBuilder
    private var summaryRows: some View {
        LabeledContent("Scan roots", value: "\(model.summary.plannedRootCount)")
        LabeledContent("Discovered", value: "\(model.summary.discoveredCount)")
        LabeledContent("Unmanaged", value: "\(model.summary.unmanagedCount)")
        LabeledContent("Ready to claim", value: "\(model.summary.claimableCount)")
        LabeledContent("Conflicts", value: "\(model.summary.conflictCount)")
        LabeledContent("Unavailable roots", value: "\(model.summary.failedRootCount)")
        if let completedAt = model.lastCompletedAt {
            LabeledContent("Last completed") {
                Text(completedAt, style: .relative)
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.loadState {
        case .blocked(let message):
            statusRow(
                title: "Discovery unavailable",
                message: message,
                systemImage: "lock.trianglebadge.exclamationmark"
            )
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Scanning registered folders…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            statusRow(
                title: "Discovery failed",
                message: message,
                systemImage: "exclamationmark.triangle"
            )
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if model.isRefreshing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Refreshing…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }

        if !model.rootDiagnostics.isEmpty {
            Section(model.items.isEmpty ? "No usable results" : "Unavailable roots") {
                ForEach(model.rootDiagnostics, id: \.self) { diagnostic in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.root.url.path)
                                .lineLimit(1)
                            Text(diagnostic.reason.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Unavailable scan root")
                    .accessibilityValue(diagnostic.accessibilitySummary)
                }
            }
        }

        if model.items.isEmpty {
            if model.rootDiagnostics.isEmpty {
                statusRow(
                    title: "No Skills found",
                    message: "The registered folders do not contain any Skills.",
                    systemImage: "sparkles"
                )
            }
        } else if items.isEmpty {
            Text("No discovered Skills match the current filter.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            Section("Discovered Skills") {
                ForEach(items) { item in
                    discoveryRow(item)
                        .tag(item.id)
                }
            }
        }
    }

    private func discoveryRow(_ item: SkillDiscoveryViewModel.Item) -> some View {
        let observation = item.observation
        return HStack(spacing: 10) {
            Image(systemName: observation.status.systemImage)
                .foregroundStyle(observation.status.tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(observation.relativeLocator)
                    .lineLimit(1)
                Text("\(observation.status.displayName) · \(observation.scopeSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(observation.relativeLocator)
        .accessibilityValue([
            observation.status.displayName,
            observation.scopeSummary,
            observation.displayURLs.first?.path,
            observation.sourceSummary,
            observation.fingerprintSummary,
            observation.reason.map(\.displayName),
        ].compactMap { $0 }.joined(separator: ", "))
        .help(observation.displayURLs.first?.path ?? observation.relativeLocator)
    }

    private func statusRow(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var isRuntimeBlocked: Bool {
        if case .blocked = model.loadState { return true }
        return false
    }
}
