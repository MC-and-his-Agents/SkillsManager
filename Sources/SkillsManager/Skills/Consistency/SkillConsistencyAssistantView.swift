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
                    Label("Refresh audit", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canRefresh)
                .keyboardShortcut("r", modifiers: [.command])
                .help("Refresh consistency audit")
                .accessibilityLabel(
                    model.canRefresh ? "Refresh consistency audit" : "Consistency audit is busy"
                )
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
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
                            Text(finding.title)
                                .lineLimit(1)
                            Text(model.isKept(finding.id) ? "Kept for now" : finding.detail)
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
                    "No matching findings",
                    systemImage: "magnifyingglass",
                    description: Text("Clear the filter to restore the complete audit.")
                )
            } else {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
            }
        }
        .searchable(text: $query, prompt: "Filter audit findings")
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if model.isPreparingPreview {
                ProgressView("Preparing preview…")
                    .controlSize(.small)
            } else if model.isExecuting {
                ProgressView("Applying changes…")
                    .controlSize(.small)
            } else if model.isVerifying {
                ProgressView("Verifying with a fresh audit…")
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
            Label(statusTitle, systemImage: statusSystemImage)
                .font(.title2)
            Text(statusDetail)
                .foregroundStyle(.secondary)
            if let snapshot = model.snapshot {
                GroupBox("Audit summary") {
                    LabeledContent("Managed Skills", value: "\(snapshot.managedSkillCount)")
                    LabeledContent("Observed directories", value: "\(snapshot.observedSkillCount)")
                    LabeledContent("Findings", value: "\(snapshot.findings.count)")
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
                Label(finding.title, systemImage: systemImage(for: finding.severity))
                    .font(.title2)
                Text(finding.detail)
                    .foregroundStyle(.secondary)
                if let locator = finding.locator {
                    GroupBox("Location") {
                        Text(locator)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if model.isKept(finding.id) {
                    Label(
                        "Kept for this session. Refreshing will show the finding again.",
                        systemImage: "clock"
                    )
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
            Text("Actions")
                .font(.headline)
            ForEach(finding.actions, id: \.self) { action in
                Button(action.title) {
                    Task {
                        await model.prepare(findingID: finding.id, action: action)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    model.isPreparingPreview
                        || model.isExecuting
                        || model.isVerifying
                        || model.snapshot?.allowsWrites != true
                )
                .accessibilityLabel("\(action.title): \(finding.title)")
                .accessibilityHint(actionHint(action))
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
                Button("Refresh audit") {
                    Task { await model.refresh() }
                }
                .disabled(!model.canRefresh)
                if currentProblem?.showsBackups == true
                    || model.snapshot?.status == .needsRepair {
                    Button("Open Skill Backups") {
                        dismiss()
                        openBackups()
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
    private var emptyDescription: String { statusDetail }

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
}

private struct SkillConsistencyPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillConsistencyViewModel.self) private var model

    let preview: SkillConsistencyViewModel.PendingPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(preview.title, systemImage: "checklist")
                .font(.title2)
            Text(preview.summary)
                .foregroundStyle(.secondary)
            GroupBox("Affected items") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preview.details, id: \.self) {
                        Text($0)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isExecuting {
                ProgressView("Applying changes…")
            } else if model.isVerifying {
                ProgressView("Verifying with a fresh audit…")
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelPreview()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isExecuting || model.isVerifying)
                Button("Confirm") {
                    Task { await model.confirmPreview() }
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
}
