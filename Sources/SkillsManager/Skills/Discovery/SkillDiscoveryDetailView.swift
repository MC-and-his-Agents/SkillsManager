import SwiftUI

struct SkillDiscoveryDetailView: View {
    @Environment(SkillDiscoveryViewModel.self) private var model

    @State private var flowErrorMessage: String?

    var body: some View {
        Group {
            switch model.loadState {
            case .blocked(let message):
                unavailableView(
                    title: "Discovery unavailable",
                    message: message,
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
            case .idle, .loading:
                ProgressView("Scanning registered folders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                unavailableView(
                    title: "Discovery failed",
                    message: message,
                    systemImage: "exclamationmark.triangle"
                )
            case .loaded:
                loadedView
            }
        }
        .navigationTitle(model.selectedItem?.observation.relativeLocator ?? "Discovery")
        .sheet(isPresented: pendingImportBinding) {
            if let pending = model.pendingImport {
                SkillDiscoveryImportConfirmationView(pending: pending)
                    .environment(model)
            }
        }
    }

    @ViewBuilder
    private var loadedView: some View {
        if let item = model.selectedItem {
            itemDetail(item)
        } else if model.items.isEmpty, !model.rootDiagnostics.isEmpty {
            failedRootsView
        } else {
            discoveryOverview
        }
    }

    private func itemDetail(_ item: SkillDiscoveryViewModel.Item) -> some View {
        let observation = item.observation
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: observation.status.systemImage)
                        .font(.title)
                        .foregroundStyle(observation.status.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(observation.relativeLocator)
                            .font(.largeTitle.bold())
                        Text(observation.status.displayName)
                            .font(.title3)
                        if let reason = observation.reason {
                            Text(reason.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)

                if let message = model.importResultMessage {
                    resultBanner(
                        message,
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                }
                if let message = model.importErrorMessage ?? flowErrorMessage {
                    resultBanner(
                        message,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                GroupBox("Local locations") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(observation.displayURLs.enumerated()), id: \.offset) {
                            index, url in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(observation.roots[index].scope.displayName)
                                    .font(.headline)
                                Text(url.path)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Discovery evidence") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Status", value: observation.status.displayName)
                        LabeledContent("Scope", value: observation.scopeSummary)
                        LabeledContent("Source", value: observation.sourceSummary)
                        LabeledContent("Content fingerprint", value: observation.fingerprintSummary)
                        if let matchedSkillID = observation.matchedSkillID {
                            LabeledContent(
                                "Matched Skill ID",
                                value: matchedSkillID.uuid.uuidString.lowercased()
                            )
                        }
                        if let reason = observation.reason {
                            LabeledContent("Reason", value: reason.displayName)
                        }
                    }
                    .padding(.top, 4)
                }

                actionSection(for: item)
                scanScopeDisclosure
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    @ViewBuilder
    private func actionSection(for item: SkillDiscoveryViewModel.Item) -> some View {
        if !item.allowedActions.isEmpty {
            GroupBox("Available action") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Preview the change before anything is written to the managed library.")
                        .foregroundStyle(.secondary)

                    HStack {
                        if item.allowedActions.contains(.claimExisting) {
                            actionButton(
                                "Preview claim",
                                systemImage: "link.badge.plus",
                                item: item,
                                action: .claimExisting
                            )
                        }
                        if item.allowedActions.contains(.importNew) {
                            actionButton(
                                item.observation.status == .conflict
                                    ? "Preview independent import"
                                    : "Preview import",
                                systemImage: "tray.and.arrow.down",
                                item: item,
                                action: .importNew
                            )
                        }
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        item: SkillDiscoveryViewModel.Item,
        action: ManagedSkillImportAction
    ) -> some View {
        Button {
            flowErrorMessage = nil
            Task {
                do {
                    try await model.prepareImport(itemID: item.id, action: action)
                } catch {
                    flowErrorMessage = error.localizedDescription
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isPreparingPreview || model.isImporting)
        .accessibilityHint("Opens a confirmation preview. No files are changed yet.")
    }

    private var discoveryOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ContentUnavailableView(
                    "Select a discovered Skill",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Review its status, evidence, and available actions.")
                )
                scanScopeDisclosure
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var failedRootsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("No usable discovery result", systemImage: "exclamationmark.triangle")
                    .font(.largeTitle.bold())
                Text("Every visible result is unavailable. Fix the folders below, then refresh.")
                    .foregroundStyle(.secondary)

                ForEach(model.rootDiagnostics, id: \.self) { diagnostic in
                    GroupBox(diagnostic.root.scope.displayName) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(diagnostic.root.url.path)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Text(diagnostic.reason.displayName)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }

    private var scanScopeDisclosure: some View {
        DisclosureGroup("Scan scope (\(model.plannedRoots.count) roots)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.plannedRoots, id: \.self) { root in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(root.scope.displayName)
                            .font(.headline)
                        Text(root.url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 8)
        }
    }

    private func resultBanner(
        _ message: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(tint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }

    private func unavailableView(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
    }

    private var pendingImportBinding: Binding<Bool> {
        Binding(
            get: { model.pendingImport != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelPendingImport()
                }
            }
        )
    }
}

private struct SkillDiscoveryImportConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillDiscoveryViewModel.self) private var model

    let pending: SkillDiscoveryViewModel.PendingImport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title.bold())
                Text(pending.preview.displayName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Change preview") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Action", value: actionName)
                    LabeledContent("Target", value: targetDescription)
                    LabeledContent("Managed result", value: managedResultDescription)
                    LabeledContent("Original folder", value: "Remains unchanged")
                    LabeledContent("Agent bindings", value: "None will be created")
                }
                .padding(.top, 4)
            }

            if let message = model.importErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    model.cancelPendingImport()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isImporting)

                Spacer()

                Button {
                    Task { await model.confirmPendingImport() }
                } label: {
                    if model.isImporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(confirmButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isImporting)
                .accessibilityLabel(
                    model.isImporting ? "Import in progress" : confirmButtonTitle
                )
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .interactiveDismissDisabled(model.isImporting)
    }

    private var title: String {
        pending.preview.action == .claimExisting ? "Confirm claim" : "Confirm import"
    }

    private var actionName: String {
        pending.preview.action == .claimExisting
            ? "Associate this local folder with an existing Skill"
            : "Import this local folder as a managed Skill"
    }

    private var targetDescription: String {
        if let id = pending.preview.matchedSkillID {
            return id.uuid.uuidString.lowercased()
        }
        if let id = pending.preview.newSkillID {
            return "New Skill ID \(id.uuid.uuidString.lowercased())"
        }
        return "New managed Skill"
    }

    private var managedResultDescription: String {
        pending.preview.action == .claimExisting
            ? "A local-origin record will be added to the matched Skill"
            : "Content will be copied into the SSOT and recorded in the database"
    }

    private var confirmButtonTitle: String {
        pending.preview.action == .claimExisting ? "Confirm claim" : "Confirm import"
    }
}
