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
                        Text("Refresh audit", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(!model.canRefresh)
                .keyboardShortcut("r", modifiers: [.command])
                .help(Text("Refresh consistency audit", bundle: .module))
                .accessibilityLabel(Text(
                    model.canRefresh ? "Refresh consistency audit" : "Consistency audit is busy",
                    bundle: .module
                ))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
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
                            Text(verbatim: finding.title)
                                .lineLimit(1)
                            Text(verbatim: model.isKept(finding.id)
                                ? localized("Kept for now")
                                : finding.detail)
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
                    localized("No matching findings"),
                    systemImage: "magnifyingglass",
                    description: Text("Clear the filter to restore the complete audit.", bundle: .module)
                )
            } else {
                ContentUnavailableView(
                    localized(emptyTitle),
                    systemImage: emptySystemImage,
                    description: Text(verbatim: localizedStatusDetail)
                )
            }
        }
        .searchable(
            text: $query,
            prompt: Text("Filter audit findings", bundle: .module)
        )
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: localized(statusTitle))
                        .font(.headline)
                    Text(verbatim: localizedStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if model.isPreparingPreview {
                ProgressView(localized("Preparing preview…"))
                    .controlSize(.small)
            } else if model.isExecuting {
                ProgressView(localized("Applying changes…"))
                    .controlSize(.small)
            } else if model.isVerifying {
                ProgressView(localized("Verifying with a fresh audit…"))
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
                Text(verbatim: localized(statusTitle))
            } icon: {
                Image(systemName: statusSystemImage)
            }
                .font(.title2)
            Text(verbatim: localizedStatusDetail)
                .foregroundStyle(.secondary)
            if let snapshot = model.snapshot {
                GroupBox {
                    LabeledContent {
                        Text(verbatim: snapshot.managedSkillCount.formatted(.number))
                    } label: {
                        Text("Managed Skills", bundle: .module)
                    }
                    LabeledContent {
                        Text(verbatim: snapshot.observedSkillCount.formatted(.number))
                    } label: {
                        Text("Observed directories", bundle: .module)
                    }
                    LabeledContent {
                        Text(verbatim: snapshot.findings.count.formatted(.number))
                    } label: {
                        Text("Findings", bundle: .module)
                    }
                } label: {
                    Text("Audit summary", bundle: .module)
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
                    Text(verbatim: finding.title)
                } icon: {
                    Image(systemName: systemImage(for: finding.severity))
                }
                    .font(.title2)
                Text(finding.detail)
                    .foregroundStyle(.secondary)
                if let locator = finding.locator {
                    GroupBox {
                        Text(locator)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Location", bundle: .module)
                    }
                }
                if model.isKept(finding.id) {
                    Label {
                        Text(
                            "Kept for this session. Refreshing will show the finding again.",
                            bundle: .module
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
            Text("Actions", bundle: .module)
                .font(.headline)
            ForEach(finding.actions, id: \.self) { action in
                Button {
                    Task {
                        await model.prepare(findingID: finding.id, action: action)
                    }
                } label: {
                    Text(verbatim: localized(action.title))
                }
                .buttonStyle(.bordered)
                .disabled(
                    model.isPreparingPreview
                        || model.isExecuting
                        || model.isVerifying
                        || model.snapshot?.allowsWrites != true
                )
                .accessibilityLabel(Text(verbatim: localized(action.title) + ": " + finding.title))
                .accessibilityHint(Text(verbatim: localized(actionHint(action))))
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
                    Text("Refresh audit", bundle: .module)
                }
                .disabled(!model.canRefresh)
                if currentProblem?.showsBackups == true
                    || model.snapshot?.status == .needsRepair {
                    Button {
                        dismiss()
                        openBackups()
                    } label: {
                        Text("Open Skill Backups", bundle: .module)
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
        case .auditing: "Reading SSOT, database, distribution targets and discovered directories."
        case .ready(let snapshot):
            switch snapshot.status {
            case .healthy:
                "SSOT, database and managed targets are consistent."
            case .findings:
                "\(snapshot.findings.count) item(s) need review."
            case .incomplete:
                "Some roots could not be inspected. Write actions are disabled."
            case .blocked:
                "A blocking library diagnostic prevents changes."
            case .operationInProgress:
                "Wait for the current operation, then refresh."
            case .needsRepair:
                "Use the existing backup and recovery tools before making more changes."
            }
        case .failed(let problem): problem.message
        }
    }

    private var localizedStatusDetail: String {
        switch model.loadState {
        case .blocked, .failed:
            statusDetail
        case .ready(let snapshot) where snapshot.status == .findings:
            statusDetail
        default:
            localized(statusDetail)
        }
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

    private var emptyTitle: String {
        if case .auditing = model.loadState { return "Auditing" }
        return statusTitle
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

    private func actionHint(_ action: SkillConsistencyPresentation.Action) -> String {
        switch action {
        case .rebuildMissingSymlinks:
            "Shows every missing Symlink before recreating them."
        case .disableMissingBinding:
            "Shows the selected managed target before disabling it."
        case .migrate:
            "Shows the source, SSOT target, backup and operation before writing."
        case .keepForNow:
            "Makes no changes. The finding returns after the next audit."
        }
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}

private struct SkillConsistencyPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillConsistencyViewModel.self) private var model

    let preview: SkillConsistencyViewModel.PendingPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(verbatim: localized(preview.title))
            } icon: {
                Image(systemName: "checklist")
            }
                .font(.title2)
            Text(verbatim: localized(preview.summary))
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
                Text("Affected items", bundle: .module)
            }
            if model.isExecuting {
                ProgressView(localized("Applying changes…"))
            } else if model.isVerifying {
                ProgressView(localized("Verifying with a fresh audit…"))
            }
            HStack {
                Spacer()
                Button {
                    model.cancelPreview()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isExecuting || model.isVerifying)
                Button {
                    Task { await model.confirmPreview() }
                } label: {
                    Text("Confirm", bundle: .module)
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

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
