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
                ProgressView(String(localized: "Scanning registered folders…", bundle: SkillsManagerLocalizationResources.bundle))
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
                ?? String(localized: "Discovery", bundle: SkillsManagerLocalizationResources.bundle)
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
                    subject: .discovery(item.id),
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
                                Text(verbatim: observation.relativeLocator)
                                    .font(.largeTitle.bold())
                                Text(verbatim: discoveryStatusText(observation.status))
                                    .font(.title3)
                                if let reason = observation.reason {
                                    Text(verbatim: discoveryReasonText(reason))
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
                                        Text(verbatim: scopeText(observation.roots[index].scope))
                                            .font(.headline)
                                        Text(verbatim: url.path)
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
                            Text("Local locations", bundle: SkillsManagerLocalizationResources.bundle)
                        }

                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                LabeledContent {
                                    Text(verbatim: discoveryStatusText(observation.status))
                                } label: {
                                    Text("Status", bundle: SkillsManagerLocalizationResources.bundle)
                                }
                                LabeledContent {
                                    Text(scopeSummaryText(observation))
                                } label: {
                                    Text("Scope", bundle: SkillsManagerLocalizationResources.bundle)
                                }
                                LabeledContent {
                                    Text(verbatim: observation.localizedSourceSummary)
                                } label: {
                                    Text("Source", bundle: SkillsManagerLocalizationResources.bundle)
                                }
                                LabeledContent {
                                    Text(observation.localizedFingerprintSummary)
                                } label: {
                                    Text("Content fingerprint", bundle: SkillsManagerLocalizationResources.bundle)
                                }
                                if let matchedSkillID = observation.matchedSkillID {
                                    LabeledContent {
                                        Text(verbatim: matchedSkillID.uuid.uuidString.lowercased())
                                    } label: {
                                        Text("Matched Skill ID", bundle: SkillsManagerLocalizationResources.bundle)
                                    }
                                }
                                if let reason = observation.reason {
                                    LabeledContent {
                                        Text(verbatim: discoveryReasonText(reason))
                                    } label: {
                                        Text("Reason", bundle: SkillsManagerLocalizationResources.bundle)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("Discovery evidence", bundle: SkillsManagerLocalizationResources.bundle)
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
                    Text("Preview the change before anything is written to the managed library.", bundle: SkillsManagerLocalizationResources.bundle)
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
                Text("Available action", bundle: SkillsManagerLocalizationResources.bundle)
            }
        }
    }

    private func actionButton(
        _ title: LocalizedStringResource,
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
                    flowErrorMessage = SkillDiscoveryViewModel.localizedErrorMessage(error)
                }
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isPreparingPreview || model.isImporting)
        .accessibilityHint(Text(
            "Opens a confirmation preview. No files are changed yet.",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
    }

    private var discoveryOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ContentUnavailableView(
                    String(localized: "Select a discovered Skill", bundle: SkillsManagerLocalizationResources.bundle),
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Review its status, evidence, and available actions.", bundle: SkillsManagerLocalizationResources.bundle)
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
                    Text("No usable discovery result", bundle: SkillsManagerLocalizationResources.bundle)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                    .font(.largeTitle.bold())
                Text("Every visible result is unavailable. Fix the folders below, then refresh.", bundle: SkillsManagerLocalizationResources.bundle)
                    .foregroundStyle(.secondary)

                ForEach(model.rootDiagnostics, id: \.self) { diagnostic in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: diagnostic.root.url.path)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Text(verbatim: discoveryReasonText(diagnostic.reason))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(verbatim: scopeText(diagnostic.root.scope))
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
                        Text(verbatim: scopeText(root.scope))
                            .font(.headline)
                        Text(verbatim: root.url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 8)
        } label: {
            Text(
                String(
                    localized: LocalizedStringResource(
            "Scan scope (\(model.plannedRoots.count) roots)",
            bundle: SkillsManagerLocalizationResources.bundle
        ))
            )
        }
    }

    private func unavailableView(
        title: LocalizedStringResource,
        message: String,
        systemImage: String
    ) -> some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            Text(verbatim: message)
        }
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

    private func discoveryStatusText(_ status: SkillDiscoveryStatus) -> String {
        return switch status {
        case .managed: String(localized: "Managed", bundle: SkillsManagerLocalizationResources.bundle)
        case .claimable: String(localized: "Ready to claim", bundle: SkillsManagerLocalizationResources.bundle)
        case .unmanaged: String(localized: "Unmanaged", bundle: SkillsManagerLocalizationResources.bundle)
        case .conflict: String(localized: "Conflict", bundle: SkillsManagerLocalizationResources.bundle)
        case .permissionDenied: String(localized: "Permission denied", bundle: SkillsManagerLocalizationResources.bundle)
        case .damaged: String(localized: "Damaged", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func discoveryReasonText(_ reason: SkillDiscoveryReason) -> String {
        return switch reason {
        case .rootPermissionDenied: String(localized: "The scan root cannot be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootChanged: String(localized: "The scan root changed while it was being inspected.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootUnsupportedType: String(localized: "The scan root is not a directory or supported link.", bundle: SkillsManagerLocalizationResources.bundle)
        case .rootReadFailed: String(localized: "The scan root could not be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unknownSymlink: String(localized: "The Skill uses a symbolic link that cannot be trusted.", bundle: SkillsManagerLocalizationResources.bundle)
        case .symbolicLinkTargetUnavailable: String(localized: "The Skill link target is unavailable.", bundle: SkillsManagerLocalizationResources.bundle)
        case .symbolicLinkTargetUnsupported: String(localized: "The Skill link target is not a directory.", bundle: SkillsManagerLocalizationResources.bundle)
        case .candidatePermissionDenied: String(localized: "The Skill folder cannot be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .sourceChanged: String(localized: "The Skill changed while it was being inspected.", bundle: SkillsManagerLocalizationResources.bundle)
        case .missingSkillManifest: String(localized: "SKILL.md is missing.", bundle: SkillsManagerLocalizationResources.bundle)
        case .containerDirectory: String(localized: "This folder contains Skill subdirectories.", bundle: SkillsManagerLocalizationResources.bundle)
        case .invalidSkillManifest: String(localized: "SKILL.md is not valid UTF-8.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unsupportedEntryType: String(localized: "The Skill contains an unsupported file type.", bundle: SkillsManagerLocalizationResources.bundle)
        case .unsafeContent: String(localized: "The Skill contains an unsafe path or link.", bundle: SkillsManagerLocalizationResources.bundle)
        case .resourceLimitExceeded: String(localized: "The Skill exceeds the safe import limits.", bundle: SkillsManagerLocalizationResources.bundle)
        case .candidateReadFailed: String(localized: "The Skill content could not be read.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousLocalAssociation: String(localized: "This location is linked to more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .localAssociationDrift: String(localized: "This location no longer matches its managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousSource: String(localized: "The source metadata matches more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .ambiguousFingerprint: String(localized: "The content matches more than one managed Skill.", bundle: SkillsManagerLocalizationResources.bundle)
        case .evidenceConflict: String(localized: "The source and content point to different managed Skills.", bundle: SkillsManagerLocalizationResources.bundle)
        case .scopeSlugConflict: String(localized: "More than one Skill uses this name in the same scope.", bundle: SkillsManagerLocalizationResources.bundle)
        }
    }

    private func scopeText(_ scope: SkillDiscoveryScope) -> String {
        let adapter: String?
        if let adapterCode = scope.adapterCode {
            switch adapterCode {
            case SkillPlatform.codex.storageKey:
                adapter = String(localized: "Codex", bundle: SkillsManagerLocalizationResources.bundle)
            case SkillPlatform.claude.storageKey:
                adapter = String(localized: "Claude Code", bundle: SkillsManagerLocalizationResources.bundle)
            case SkillPlatform.opencode.storageKey:
                adapter = String(localized: "OpenCode", bundle: SkillsManagerLocalizationResources.bundle)
            case SkillPlatform.copilot.storageKey:
                adapter = String(localized: "GitHub Copilot", bundle: SkillsManagerLocalizationResources.bundle)
            default:
                adapter = adapterCode
            }
        } else {
            adapter = nil
        }
        switch scope.kind {
        case .global: return String(localized: "Global", bundle: SkillsManagerLocalizationResources.bundle)
        case .agent:
            return [adapter, scope.pathVariant].compactMap { $0 }.joined(separator: " · ")
        case .custom:
            return [String(localized: "Custom", bundle: SkillsManagerLocalizationResources.bundle), adapter, scope.pathVariant]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    private func scopeSummaryText(_ observation: SkillDiscoveryObservation) -> String {
        Array(Set(observation.roots.map { scopeText($0.scope) }))
            .sorted()
            .joined(separator: ", ")
    }

}

private struct SkillDiscoveryImportConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillDiscoveryViewModel.self) private var model

    let pending: SkillDiscoveryViewModel.PendingImport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: titleText)
                    .font(.title.bold())
                Text(verbatim: pending.preview.displayName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent {
                        Text(verbatim: actionName)
                    } label: {
                        Text("Action", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text(verbatim: targetDescription)
                    } label: {
                        Text("Target", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text(verbatim: managedResultDescriptionText)
                    } label: {
                        Text("Managed result", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text("Remains unchanged", bundle: SkillsManagerLocalizationResources.bundle)
                    } label: {
                        Text("Original folder", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                    LabeledContent {
                        Text("None will be created", bundle: SkillsManagerLocalizationResources.bundle)
                    } label: {
                        Text("Agent bindings", bundle: SkillsManagerLocalizationResources.bundle)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Change preview", bundle: SkillsManagerLocalizationResources.bundle)
            }

            if let message = model.importErrorMessage {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .foregroundStyle(.orange)
                    .accessibilityElement(children: .combine)
            }

            Spacer()

            HStack {
                Button {
                    model.cancelPendingImport()
                    dismiss()
                } label: {
                    Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
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
                        Text(verbatim: confirmButtonTitleText)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isImporting)
                .accessibilityLabel(Text(verbatim: model.isImporting
                    ? String(localized: "Import in progress", bundle: SkillsManagerLocalizationResources.bundle)
                    : confirmButtonTitleText))
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .interactiveDismissDisabled(model.isImporting)
    }

    private var titleText: String {
        String(localized: pending.preview.action == .claimExisting
            ? "Confirm claim"
            : "Confirm import", bundle: SkillsManagerLocalizationResources.bundle)
    }

    private var actionName: String {
        pending.preview.action == .claimExisting
            ? String(localized: "Associate this local folder with an existing Skill", bundle: SkillsManagerLocalizationResources.bundle)
            : String(localized: "Import this local folder as a managed Skill", bundle: SkillsManagerLocalizationResources.bundle)
    }

    private var targetDescription: String {
        if let id = pending.preview.matchedSkillID {
            return id.uuid.uuidString.lowercased()
        }
        if let id = pending.preview.newSkillID {
            return String(localized: LocalizedStringResource(
                "New Skill ID \(id.uuid.uuidString.lowercased())",
                bundle: SkillsManagerLocalizationResources.bundle
            ))
        }
        return String(localized: "New managed Skill", bundle: SkillsManagerLocalizationResources.bundle)
    }

    private var managedResultDescriptionText: String {
        pending.preview.action == .claimExisting
            ? String(localized: "A local-origin record will be added to the matched Skill", bundle: SkillsManagerLocalizationResources.bundle)
            : String(localized: "Content will be copied into the SSOT and recorded in the database", bundle: SkillsManagerLocalizationResources.bundle)
    }

    private var confirmButtonTitleText: String {
        titleText
    }
}
