import SwiftUI

struct SkillUpdateCheckView: View {
    @Environment(SkillUpdateCheckViewModel.self) private var model

    var body: some View {
        GroupBox("Update check") {
            VStack(alignment: .leading, spacing: 10) {
                stateContent
                if let problem = model.problem {
                    Label(
                        problem.localizedDescription,
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.loadState {
        case .blocked(let message):
            status(message, systemImage: "lock.trianglebadge.exclamationmark")
        case .empty:
            status("Select a managed Skill to check for updates.", systemImage: "arrow.clockwise")
        case .loading:
            ProgressView("Loading the last update check…")
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 8) {
                status(problem.localizedDescription, systemImage: "exclamationmark.triangle")
                Button("Retry") { Task { await model.refreshCurrent() } }
            }
        case .loaded(let snapshot):
            loaded(snapshot)
        }
    }

    private func loaded(_ snapshot: ManagedSkillUpdateCheckSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot {
                Label(
                    snapshot.status.displayName,
                    systemImage: snapshot.status.systemImage
                )
                .font(.headline)
                .accessibilityLabel("Update status: \(snapshot.status.displayName)")
                Text(
                    Date(
                        timeIntervalSince1970:
                            Double(snapshot.checkedAtMilliseconds) / 1_000
                    ).formatted(date: .abbreviated, time: .shortened)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let reason = snapshot.capabilityReason {
                    Text(reason).foregroundStyle(.secondary)
                }
                if !snapshot.sourceChangedScopeKeys.isEmpty {
                    Label(
                        "Copy content is behind the managed Skill and needs to be synchronized.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text("This Skill has not been checked yet.")
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.checkCurrent() }
            } label: {
                if model.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isChecking)
            .accessibilityLabel(model.isChecking ? "Checking for updates" : "Check for updates")
        }
    }

    private func status(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}

private extension ManagedSkillUpdateCheckStatus {
    var displayName: String {
        switch self {
        case .upToDate: "Up to date"
        case .remoteChanged: "Update available"
        case .localModified: "Managed content was modified locally"
        case .copyDrift: "Copy target has local changes"
        case .capabilityUnavailable: "Update checking unavailable"
        case .conflict: "Update state needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .upToDate: "checkmark.circle"
        case .remoteChanged: "arrow.down.circle"
        case .localModified: "pencil.circle"
        case .copyDrift: "exclamationmark.arrow.triangle.2.circlepath"
        case .capabilityUnavailable: "questionmark.circle"
        case .conflict: "exclamationmark.triangle"
        }
    }
}
