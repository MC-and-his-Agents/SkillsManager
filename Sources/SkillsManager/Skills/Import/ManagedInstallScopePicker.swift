import SwiftUI

enum ManagedInstallDistributionMode: String, CaseIterable, Identifiable {
    case global = "Global"
    case agents = "Agent-specific"

    var id: Self { self }
}

struct ManagedInstallScopePicker: View {
    @Binding var mode: ManagedInstallDistributionMode
    @Binding var selectedAgents: Set<SkillPlatform>
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enable for", bundle: .module)
                .font(.headline)
            Picker(selection: $mode) {
                ForEach(ManagedInstallDistributionMode.allCases) { option in
                    Text(verbatim: modeText(option)).tag(option)
                }
            } label: {
                Text("Distribution scope", bundle: .module)
            }
            .pickerStyle(.segmented)
            .disabled(isDisabled)

            if mode == .global {
                globalSummary
            } else {
                agentSelection
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var globalSummary: some View {
        Group {
            Text(
                String(
                    localized: LocalizedStringResource(
            "Compatible Agents share one managed link in \(DistributionTargetCatalog.current.globalTarget.rootLocator).",
            bundle: .module
        ))
            )
            Text(verbatim: DistributionTargetCatalog.current.globalReaders
                .map(platformText)
                .joined(separator: ", "))
            .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var agentSelection: some View {
        Group {
            ForEach(SkillPlatform.allCases) { platform in
                Toggle(
                    isOn: Binding(
                        get: { selectedAgents.contains(platform) },
                        set: { selected in
                            if selected {
                                selectedAgents.insert(platform)
                            } else {
                                selectedAgents.remove(platform)
                            }
                        }
                    )
                ) {
                    Text(verbatim: platformText(platform))
                }
                .toggleStyle(.checkbox)
                .disabled(isDisabled)
            }
            if selectedAgents.isEmpty {
                Label {
                    Text("Select at least one Agent.", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                    .foregroundStyle(.orange)
            }
        }
    }

    private func modeText(_ mode: ManagedInstallDistributionMode) -> String {
        switch mode {
        case .global: String(localized: "Global", bundle: .module)
        case .agents: String(localized: "Agent-specific", bundle: .module)
        }
    }

    private func platformText(_ platform: SkillPlatform) -> String {
        switch platform {
        case .codex: String(localized: "Codex", bundle: .module)
        case .claude: String(localized: "Claude Code", bundle: .module)
        case .opencode: String(localized: "OpenCode", bundle: .module)
        case .copilot: String(localized: "GitHub Copilot", bundle: .module)
        }
    }
}
