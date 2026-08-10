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
                ProgressView(localized("Scanning registered folders…"))
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
        .navigationTitle(
            model.selectedItem?.observation.relativeLocator
                ?? String(localized: "Discovery", bundle: .module)
        )
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
        let isManagedMatch = observation.status == .managed
            && observation.matchedSkillID != nil
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if isManagedMatch {
                    SkillDiscoveryActionBar(
                        item: item,
                        onFullSettings: {
                            withAnimation {
                                proxy.scrollTo(
                                    "discovered-distribution-editor",
                                    anchor: .top
                                )
                            }
                        }
                    )
                }
                SkillDetailFeedbackBanner(
                    skillID: item.id.relativeLocatorKey,
                    extraErrorMessage: flowErrorMessage
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: observation.status.systemImage)
                                .font(.title)
                                .foregroundStyle(observation.status.tint)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(observation.relativeLocator)
                                    .font(.largeTitle.bold())
                                Text(localized(observation.status.displayName))
                                    .font(.title3)
                                if let reason = observation.reason {
                                    Text(localized(reason.displayName))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)

                        GroupBox {
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
                        } label: {
                            Text("Local locations", bundle: .module)
                        }

                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                LabeledContent {
                                    Text(localized(observation.status.displayName))
                                } label: {
                                    Text("Status", bundle: .module)
                                }
                                LabeledContent("Scope", value: observation.scopeSummary)
                                LabeledContent("Source", value: observation.sourceSummary)
                                LabeledContent {
                                    Text(observation.fingerprintSummary)
                                } label: {
                                    Text("Content fingerprint", bundle: .module)
                                }
                                if let matchedSkillID = observation.matchedSkillID {
                                    LabeledContent {
                                        Text(matchedSkillID.uuid.uuidString.lowercased())
                                    } label: {
                                        Text("Matched Skill ID", bundle: .module)
                                    }
                                }
                                if let reason = observation.reason {
                                    LabeledContent {
                                        Text(localized(reason.displayName))
                                    } label: {
                                        Text("Reason", bundle: .module)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("Discovery evidence", bundle: .module)
                        }

                        if isManagedMatch {
                            SkillDistributionView()
                                .id("discovered-distribution-editor")
                            SkillUpdateCheckView()
                            SkillDeletionView()
                        }

                        actionSection(for: item)
                        scanScopeDisclosure
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
    }

    @ViewBuilder
    private func actionSection(for item: SkillDiscoveryViewModel.Item) -> some View {
        if !item.allowedActions.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Preview the change before anything is written to the managed library.", bundle: .module)
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
            } label: {
                Text("Available action", bundle: .module)
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
            Label {
                Text(verbatim: localized(title))
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isPreparingPreview || model.isImporting)
        .accessibilityHint(Text(
            "Opens a confirmation preview. No files are changed yet.",
            bundle: .module
        ))
    }

    private var discoveryOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ContentUnavailableView(
                    "Select a discovered Skill",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Review its status, evidence, and available actions.", bundle: .module)
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
                Label {
                    Text("No usable discovery result", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                    .font(.largeTitle.bold())
                Text("Every visible result is unavailable. Fix the folders below, then refresh.", bundle: .module)
                    .foregroundStyle(.secondary)

                ForEach(model.rootDiagnostics, id: \.self) { diagnostic in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(diagnostic.root.url.path)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Text(localized(diagnostic.reason.displayName))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(localized(diagnostic.root.scope.displayName))
                    }
                }
            }
            .padding()
        }
    }

    private var scanScopeDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.plannedRoots, id: \.self) { root in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized(root.scope.displayName))
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
        } label: {
            Text("Scan scope (\(model.plannedRoots.count) roots)", bundle: .module)
        }
    }

    private func unavailableView(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        ContentUnavailableView(
            localized(title),
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

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
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

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent {
                        Text(localized(actionName))
                    } label: {
                        Text("Action", bundle: .module)
                    }
                    LabeledContent {
                        Text(targetDescription)
                    } label: {
                        Text("Target", bundle: .module)
                    }
                    LabeledContent {
                        Text(localized(managedResultDescription))
                    } label: {
                        Text("Managed result", bundle: .module)
                    }
                    LabeledContent {
                        Text("Remains unchanged", bundle: .module)
                    } label: {
                        Text("Original folder", bundle: .module)
                    }
                    LabeledContent {
                        Text("None will be created", bundle: .module)
                    } label: {
                        Text("Agent bindings", bundle: .module)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Change preview", bundle: .module)
            }

            if let message = model.importErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }

            Spacer()

            HStack {
                Button {
                    model.cancelPendingImport()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: .module)
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
                        Text(verbatim: localized(confirmButtonTitle))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isImporting)
                .accessibilityLabel(Text(verbatim: localized(
                    model.isImporting ? "Import in progress" : confirmButtonTitle
                )))
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

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
