import SwiftUI

struct SkillConsistencyAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillConsistencyViewModel.self) private var model
    @State private var selectedFindingID: String?
    @State private var query = ""

    let openBackups: () -> Void

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label {
                        Text("Refresh audit", bundle: SkillsManagerLocalizationResources.bundle)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(!model.canRefresh)
                .keyboardShortcut("r", modifiers: [.command])
                .help(Text("Refresh consistency audit", bundle: SkillsManagerLocalizationResources.bundle))
                .accessibilityLabel(Text(
                    model.canRefresh ? "Refresh consistency audit" : "Consistency audit is busy",
                    bundle: SkillsManagerLocalizationResources.bundle
                ))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: SkillsManagerLocalizationResources.bundle)
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isExecuting)
            }
        }
        .sheet(item: previewBinding) { preview in
            SkillConsistencyPreviewView(preview: preview)
                .environment(model)
        }
        .interactiveDismissDisabled(model.isExecuting)
        .task { await model.refresh() }
        .onChange(of: findingIDs, initial: true) { _, ids in
            if let selectedFindingID, ids.contains(selectedFindingID) { return }
            selectedFindingID = ids.first
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            if model.snapshot?.findings.isEmpty == false, !visibleFindings.isEmpty {
                List(visibleFindings, selection: $selectedFindingID) { finding in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(findingTitleText(finding.title))
                                .lineLimit(1)
                            Text(verbatim: model.isKept(finding.id)
                                ? String(localized: "Kept for now", bundle: SkillsManagerLocalizationResources.bundle)
                                : findingDetailText(finding.detail))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: systemImage(for: finding.severity))
                            .foregroundStyle(tint(for: finding.severity))
                    }
                    .tag(finding.id)
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.sidebar)
            } else if model.snapshot?.findings.isEmpty == false {
                ContentUnavailableView(
                    String(localized: "No matching findings", bundle: SkillsManagerLocalizationResources.bundle),
                    systemImage: "magnifyingglass",
                    description: Text("Clear the filter to restore the complete audit.", bundle: SkillsManagerLocalizationResources.bundle)
                )
            } else {
                ContentUnavailableView(
                    emptyTitleText,
                    systemImage: emptySystemImage,
                    description: Text(verbatim: statusDetailText)
                )
            }
        }
        .searchable(
            text: $query,
            prompt: Text("Filter audit findings", bundle: SkillsManagerLocalizationResources.bundle)
        )
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: statusTitleText)
                        .font(.headline)
                    Text(verbatim: statusDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if model.isPreparingPreview {
                ProgressView(String(localized: "Preparing preview…", bundle: SkillsManagerLocalizationResources.bundle))
                    .controlSize(.small)
            } else if model.isExecuting {
                ProgressView(String(localized: "Applying changes…", bundle: SkillsManagerLocalizationResources.bundle))
                    .controlSize(.small)
            } else if model.isVerifying {
                ProgressView(String(localized: "Verifying with a fresh audit…", bundle: SkillsManagerLocalizationResources.bundle))
                    .controlSize(.small)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detail: some View {
        if let finding = selectedFinding {
            findingDetail(finding)
        } else {
            overview
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(verbatim: statusTitleText)
            } icon: {
                Image(systemName: statusSystemImage)
            }
                .font(.title2)
            Text(verbatim: statusDetailText)
                .foregroundStyle(.secondary)
            if let snapshot = model.snapshot {
                GroupBox {
                    LabeledContent {
                        Text(verbatim: snapshot.managedSkillCount.formatted(.number))
                    } label: {
                        Text("Managed Skills", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text(verbatim: snapshot.observedSkillCount.formatted(.number))
                    } label: {
                        Text("Observed directories", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text(verbatim: snapshot.findings.count.formatted(.number))
                    } label: {
                        Text("Findings", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                } label: {
                    Text("Audit summary", bundle: SkillsManagerLocalizationResources.bundle)
                }
            }
            feedback
            recoveryActions
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func findingDetail(
        _ finding: SkillConsistencyPresentation.Finding
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label {
                    Text(findingTitleText(finding.title))
                } icon: {
                    Image(systemName: systemImage(for: finding.severity))
                }
                    .font(.title2)
                Text(findingDetailText(finding.detail))
                    .foregroundStyle(.secondary)
                if let locator = finding.locator {
                    GroupBox {
                        Text(locator)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Location", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                }
                if model.isKept(finding.id) {
                    Label {
                        Text(
                            "Kept for this session. Refreshing will show the finding again.",
                            bundle: SkillsManagerLocalizationResources.bundle
                        )
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    actionButtons(finding)
                }
                feedback
                recoveryActions
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionButtons(
        _ finding: SkillConsistencyPresentation.Finding
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.headline)
            ForEach(finding.actions, id: \.self) { action in
                Button {
                    Task {
                        await model.prepare(findingID: finding.id, action: action)
                    }
                } label: {
                    Text(verbatim: actionTitle(action))
                }
                .buttonStyle(.bordered)
                .disabled(
                    model.isPreparingPreview
                        || model.isExecuting
                        || model.isVerifying
                        || model.snapshot?.allowsWrites != true
                )
                .accessibilityLabel(Text(actionAccessibilityLabel(action, finding: finding)))
                .accessibilityHint(Text(actionHintText(action)))
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let success = model.successMessage {
            Label(success, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
        }
        if let problem = currentProblem {
            Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if currentProblem != nil || model.snapshot?.status == .needsRepair
            || model.snapshot?.status == .operationInProgress {
            HStack {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Text("Refresh audit", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .disabled(!model.canRefresh)
                if currentProblem?.showsBackups == true
                    || model.snapshot?.status == .needsRepair {
                    Button {
                        dismiss()
                        openBackups()
                    } label: {
                        Text("Open Skill Backups", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    .disabled(model.isExecuting)
                }
            }
        }
    }

    private var previewBinding: Binding<SkillConsistencyViewModel.PendingPreview?> {
        Binding(
            get: { model.pendingPreview },
            set: { if $0 == nil { model.cancelPreview() } }
        )
    }

    private var findingIDs: [String] {
        visibleFindings.map(\.id)
    }

    private var visibleFindings: [SkillConsistencyPresentation.Finding] {
        SkillConsistencyPresentation.filteredFindings(
            model.snapshot?.findings ?? [],
            query: query
        )
    }

    private var selectedFinding: SkillConsistencyPresentation.Finding? {
        guard let selectedFindingID else { return nil }
        return visibleFindings.first { $0.id == selectedFindingID }
    }

    private var currentProblem: SkillConsistencyViewModel.Problem? {
        if case .failed(let problem) = model.loadState { return problem }
        return model.problem
    }

    private var statusTitle: String {
        switch model.loadState {
        case .blocked: "Consistency audit"
        case .auditing: "Auditing"
        case .ready(let snapshot): snapshot.status.title
        case .failed: "Audit unavailable"
        }
    }

    private var statusDetail: String {
        switch model.loadState {
        case .blocked(let message): message
        case .auditing:
            String(localized: "Reading SSOT, database, distribution targets and discovered directories.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ready(let snapshot):
            switch snapshot.status {
            case .healthy:
                String(localized: "SSOT, database and managed targets are consistent.", bundle: SkillsManagerLocalizationResources.bundle)
            case .findings:
                findingsStatusText(count: snapshot.findings.count)
            case .incomplete:
                String(localized: "Some roots could not be inspected. Write actions are disabled.", bundle: SkillsManagerLocalizationResources.bundle)
            case .blocked:
                String(localized: "A blocking library diagnostic prevents changes.", bundle: SkillsManagerLocalizationResources.bundle)
            case .operationInProgress:
                String(localized: "Wait for the current operation, then refresh.", bundle: SkillsManagerLocalizationResources.bundle)
            case .needsRepair:
                String(localized: "Use the existing backup and recovery tools before making more changes.", bundle: SkillsManagerLocalizationResources.bundle)
            }
        case .failed(let problem): problem.message
        }
    }

    private var statusTitleText: String {
        switch model.loadState {
        case .blocked: String(localized: "Consistency audit", bundle: SkillsManagerLocalizationResources.bundle)
        case .auditing: String(localized: "Auditing", bundle: SkillsManagerLocalizationResources.bundle)
        case .ready(let snapshot): consistencyStatusText(snapshot.status)
        case .failed: String(localized: "Audit unavailable", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private var statusDetailText: String {
        switch model.loadState {
        case .blocked, .failed:
            statusDetail
        case .ready(let snapshot) where snapshot.status == .findings:
            findingsStatusText(count: snapshot.findings.count)
        case .auditing:
            String(localized: "Reading SSOT, database, distribution targets and discovered directories.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ready(let snapshot):
            switch snapshot.status {
            case .healthy:
                String(localized: "SSOT, database and managed targets are consistent.", bundle: SkillsManagerLocalizationResources.bundle)
            case .incomplete:
                String(localized: "Some roots could not be inspected. Write actions are disabled.", bundle: SkillsManagerLocalizationResources.bundle)
            case .blocked:
                String(localized: "A blocking library diagnostic prevents changes.", bundle: SkillsManagerLocalizationResources.bundle)
            case .operationInProgress:
                String(localized: "Wait for the current operation, then refresh.", bundle: SkillsManagerLocalizationResources.bundle)
            case .needsRepair:
                String(localized: "Use the existing backup and recovery tools before making more changes.", bundle: SkillsManagerLocalizationResources.bundle)
            case .findings:
                findingsStatusText(count: snapshot.findings.count)
            }
        }
    }

    private func findingsStatusText(count: Int) -> String {
        String(
            localized: LocalizedStringResource(
            "\(count) items need review.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }

    private var statusSystemImage: String {
        if case .ready(let snapshot) = model.loadState {
            return snapshot.status.systemImage
        }
        if case .auditing = model.loadState { return "magnifyingglass" }
        return "exclamationmark.triangle"
    }

    private var statusIcon: some View {
        Image(systemName: statusSystemImage)
            .font(.title3)
            .foregroundStyle(statusTint)
    }

    private var statusTint: Color {
        if case .ready(let snapshot) = model.loadState {
            return switch snapshot.status {
            case .healthy: .green
            case .findings: .orange
            default: .red
            }
        }
        return .secondary
    }

    private var emptyTitleText: String {
        if case .auditing = model.loadState {
            return String(localized: "Auditing", bundle: SkillsManagerLocalizationResources.bundle)
        }
        return statusTitleText
    }

    private var emptySystemImage: String { statusSystemImage }
    private func systemImage(
        for severity: SkillConsistencyPresentation.Severity
    ) -> String {
        switch severity {
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocking: "xmark.octagon"
        }
    }

    private func tint(
        for severity: SkillConsistencyPresentation.Severity
    ) -> Color {
        switch severity {
        case .information: .secondary
        case .warning: .orange
        case .blocking: .red
        }
    }

    private func actionHintText(_ action: SkillConsistencyPresentation.Action) -> String {
        return switch action {
        case .rebuildMissingSymlinks:
            String(localized: "Shows every missing Symlink before recreating them.", bundle: SkillsManagerLocalizationResources.bundle)
        case .disableMissingBinding:
            String(localized: "Shows the selected managed target before disabling it.", bundle: SkillsManagerLocalizationResources.bundle)
        case .migrate:
            String(localized: "Shows the source, SSOT target, backup and operation before writing.", bundle: SkillsManagerLocalizationResources.bundle)
        case .keepForNow:
            String(localized: "Makes no changes. The finding returns after the next audit.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func actionAccessibilityLabel(
        _ action: SkillConsistencyPresentation.Action,
        finding: SkillConsistencyPresentation.Finding
    ) -> String {
        let title = findingTitleText(finding.title)
        return String(localized: LocalizedStringResource(
            "\(actionTitle(action)): \(title)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }

    private func findingTitleText(_ title: String) -> String {
        if let code = LibraryDiagnosticCode(rawValue: title) {
            return localizedLibraryDiagnosticCode(code)
        }
        guard let separator = title.range(of: " · ") else { return title }
        let name = String(title[..<separator.lowerBound])
        let scope = String(title[separator.upperBound...])
        let localizedScope: String
        switch scope {
        case "All compatible Agents":
            localizedScope = String(localized: "All compatible Agents", bundle: SkillsManagerLocalizationResources.bundle)
        case SkillPlatform.codex.rawValue:
            localizedScope = String(localized: "Codex", bundle: SkillsManagerLocalizationResources.bundle)
        case SkillPlatform.claude.rawValue:
            localizedScope = String(localized: "Claude Code", bundle: SkillsManagerLocalizationResources.bundle)
        case SkillPlatform.opencode.rawValue:
            localizedScope = String(localized: "OpenCode", bundle: SkillsManagerLocalizationResources.bundle)
        case SkillPlatform.copilot.rawValue:
            localizedScope = String(localized: "GitHub Copilot", bundle: SkillsManagerLocalizationResources.bundle)
        default:
            localizedScope = scope
        }
        return String(localized: LocalizedStringResource(
            "\(name) · \(localizedScope)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }

    private func findingDetailText(_ detail: String) -> String {
        switch detail {
        case "The managed link points to a different Skill.":
            return String(localized: "The managed link points to a different Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The managed Symlink is missing.":
            return String(localized: "The managed Symlink is missing.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The managed target is missing and requires a Copy/Fork decision.":
            return String(localized: "The managed target is missing and requires a Copy/Fork decision.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The managed Copy has changed and requires an explicit Fork decision.":
            return String(localized: "The managed Copy has changed and requires an explicit Fork decision.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Another file or directory occupies this managed target.":
            return String(localized: "Another file or directory occupies this managed target.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This target could not be inspected.":
            return String(localized: "This target could not be inspected.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The target state is not supported by this repair assistant.":
            return String(localized: "The target state is not supported by this repair assistant.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The audit could not bind this directory to one stable observation.":
            return String(localized: "The audit could not bind this directory to one stable observation.", bundle: SkillsManagerLocalizationResources.bundle)
        case "The audit found duplicate observations for the same directory.":
            return String(localized: "The audit found duplicate observations for the same directory.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Conflicting identity evidence requires import as an independent Skill.":
            return String(localized: "Conflicting identity evidence requires import as an independent Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This directory is not yet distributed through the managed library.":
            return String(localized: "This directory is not yet distributed through the managed library.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This directory is not associated with a registered scan root.":
            return String(localized: "This directory is not associated with a registered scan root.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This directory belongs to a custom scan root and cannot be migrated.":
            return String(localized: "This directory belongs to a custom scan root and cannot be migrated.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This directory could not produce a stable content snapshot.":
            return String(localized: "This directory could not produce a stable content snapshot.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This directory name is not a safe canonical locator.":
            return String(localized: "This directory name is not a safe canonical locator.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This Agent directory is not a canonical managed distribution root.":
            return String(localized: "This Agent directory is not a canonical managed distribution root.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This directory is not in a canonical managed distribution root.":
            return String(localized: "This directory is not in a canonical managed distribution root.", bundle: SkillsManagerLocalizationResources.bundle)
        case let value where value.hasPrefix("Recommended action: "):
            let code = String(value.dropFirst("Recommended action: ".count))
            return String(localized: LocalizedStringResource(
                "Recommended action: \(localizedRecommendedActionCode(code))",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        case let value where value.hasPrefix("The root could not be fully audited: "):
            let reason = String(value.dropFirst("The root could not be fully audited: ".count))
            return String(localized: LocalizedStringResource(
                "The root could not be fully audited: \(localizedConsistencyDiscoveryReason(reason))",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        case let value where value.hasPrefix("This directory cannot be safely imported: "):
            let reason = String(value.dropFirst("This directory cannot be safely imported: ".count))
            return String(localized: LocalizedStringResource(
                "This directory cannot be safely imported: \(localizedConsistencyDiscoveryReason(reason))",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        case "This external Skill link changed after it was imported. Review it in Discovery; no files were changed.":
            return String(localized: "This external Skill link changed after it was imported. Review it in Discovery; no files were changed.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This external Skill link can be imported from Discovery. The source link and target will remain unchanged.":
            return String(localized: "This external Skill link can be imported from Discovery. The source link and target will remain unchanged.", bundle: SkillsManagerLocalizationResources.bundle)
        case "This directory is visible through multiple registered root aliases. Review it in Discovery; automatic migration is disabled.":
            return String(localized: "This directory is visible through multiple registered root aliases. Review it in Discovery; automatic migration is disabled.", bundle: SkillsManagerLocalizationResources.bundle)
        default:
            return detail
        }
    }

    private func consistencyStatusText(_ status: SkillConsistencyPresentation.Status) -> String {
        return switch status {
        case .healthy: String(localized: "Healthy", bundle: SkillsManagerLocalizationResources.bundle)
        case .findings: String(localized: "Review needed", bundle: SkillsManagerLocalizationResources.bundle)
        case .incomplete: String(localized: "Audit incomplete", bundle: SkillsManagerLocalizationResources.bundle)
        case .blocked: String(localized: "Library unavailable", bundle: SkillsManagerLocalizationResources.bundle)
        case .operationInProgress: String(localized: "Operation in progress", bundle: SkillsManagerLocalizationResources.bundle)
        case .needsRepair: String(localized: "Repair required", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func actionTitle(_ action: SkillConsistencyPresentation.Action) -> String {
        return switch action {
        case .rebuildMissingSymlinks:
            String(localized: "Rebuild missing links", bundle: SkillsManagerLocalizationResources.bundle)
        case .disableMissingBinding:
            String(localized: "Disable missing target", bundle: SkillsManagerLocalizationResources.bundle)
        case .migrate(.importNew, true):
            String(localized: "Import as independent Skill, back up and migrate", bundle: SkillsManagerLocalizationResources.bundle)
        case .migrate(.importNew, false):
            String(localized: "Import, back up and migrate", bundle: SkillsManagerLocalizationResources.bundle)
        case .migrate(.claimExisting, _):
            String(localized: "Claim, back up and migrate", bundle: SkillsManagerLocalizationResources.bundle)
        case .migrate(nil, _):
            String(localized: "Back up and migrate", bundle: SkillsManagerLocalizationResources.bundle)
        case .keepForNow:
            String(localized: "Keep for now", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

}

private struct SkillConsistencyPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillConsistencyViewModel.self) private var model

    let preview: SkillConsistencyViewModel.PendingPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(verbatim: previewTitleText(preview.title))
            } icon: {
                Image(systemName: "checklist")
            }
                .font(.title2)
            Text(verbatim: previewSummaryText(preview.summary))
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preview.details, id: \.self) {
                        Text($0)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Affected items", bundle: SkillsManagerLocalizationResources.bundle)
            }
            if model.isExecuting {
                ProgressView(String(localized: "Applying changes…", bundle: SkillsManagerLocalizationResources.bundle))
            } else if model.isVerifying {
                ProgressView(String(localized: "Verifying with a fresh audit…", bundle: SkillsManagerLocalizationResources.bundle))
            }
            HStack {
                Spacer()
                Button {
                    model.cancelPreview()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isExecuting || model.isVerifying)
                Button {
                    Task { await model.confirmPreview() }
                } label: {
                    Text("Confirm", bundle: SkillsManagerLocalizationResources.bundle)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.isExecuting || model.isVerifying)
            }
        }
        .padding(24)
        .frame(minWidth: 560)
        .interactiveDismissDisabled(model.isExecuting || model.isVerifying)
    }

    private func previewTitleText(_ title: String) -> String {
        return switch title {
        case "Rebuild missing links": String(localized: "Rebuild missing links", bundle: SkillsManagerLocalizationResources.bundle)
        case "Disable missing target": String(localized: "Disable missing target", bundle: SkillsManagerLocalizationResources.bundle)
        case "Import, back up and migrate": String(localized: "Import, back up and migrate", bundle: SkillsManagerLocalizationResources.bundle)
        case "Claim, back up and migrate": String(localized: "Claim, back up and migrate", bundle: SkillsManagerLocalizationResources.bundle)
        case "Back up and migrate": String(localized: "Back up and migrate", bundle: SkillsManagerLocalizationResources.bundle)
        default: title
        }
    }

    private func previewSummaryText(_ summary: String) -> String {
        return switch summary {
        case "Recreate every missing managed Symlink for this Skill.":
            String(localized: "Recreate every missing managed Symlink for this Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Remove the selected missing target from managed distribution.":
            String(localized: "Remove the selected missing target from managed distribution.", bundle: SkillsManagerLocalizationResources.bundle)
        case "Back up the original directory, then replace it with a managed Symlink.":
            String(localized: "Back up the original directory, then replace it with a managed Symlink.", bundle: SkillsManagerLocalizationResources.bundle)
        default: summary
        }
    }
}
