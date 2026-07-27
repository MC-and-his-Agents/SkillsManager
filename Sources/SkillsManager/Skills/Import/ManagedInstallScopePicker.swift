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
            Text("Enable for")
                .font(.headline)
            Picker("Distribution scope", selection: $mode) {
                ForEach(ManagedInstallDistributionMode.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
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
                "Compatible Agents share one managed link in "
                    + DistributionTargetCatalog.current.globalTarget.rootLocator + "."
            )
            Text(
                DistributionTargetCatalog.current.globalReaders
                    .map(\.rawValue)
                    .joined(separator: ", ")
            )
            .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var agentSelection: some View {
        Group {
            ForEach(SkillPlatform.allCases) { platform in
                Toggle(
                    platform.rawValue,
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
                )
                .toggleStyle(.checkbox)
                .disabled(isDisabled)
            }
            if selectedAgents.isEmpty {
                Label("Select at least one Agent.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }
}
