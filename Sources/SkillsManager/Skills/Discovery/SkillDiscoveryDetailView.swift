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
                ProgressView(String(localized: "Scanning registered folders…", bundle: .module))
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
                                    Text(verbatim: discoveryStatusText(observation.status))
                                } label: {
                                    Text("Status", bundle: .module)
                                }
                                    LabeledContent("Scope", value: scopeSummaryText(observation))
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
                                        Text(verbatim: discoveryReasonText(reason))
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
                Text(verbatim: actionTitleText(title))
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
                    String(localized: "Select a discovered Skill", bundle: .module),
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
            Text(
                String(
                    localized: LocalizedStringResource( "Scan scope (%lld roots)",
                    defaultValue: "Scan scope (\(model.plannedRoots.count) roots)",
                    bundle: .module
                ))
            )
        }
    }

    private func unavailableView(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        ContentUnavailableView(
            unavailableTitleText(title),
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

    private func discoveryStatusText(_ status: SkillDiscoveryStatus) -> String {
        return switch status {
        case .managed: String(localized: "Managed", bundle: .module)
        case .claimable: String(localized: "Ready to claim", bundle: .module)
        case .unmanaged: String(localized: "Unmanaged", bundle: .module)
        case .conflict: String(localized: "Conflict", bundle: .module)
        case .permissionDenied: String(localized: "Permission denied", bundle: .module)
        case .damaged: String(localized: "Damaged", bundle: .module)
        }
    }

    private func discoveryReasonText(_ reason: SkillDiscoveryReason) -> String {
        return switch reason {
        case .rootPermissionDenied: String(localized: "The scan root cannot be read.", bundle: .module)
        case .rootChanged: String(localized: "The scan root changed while it was being inspected.", bundle: .module)
        case .rootUnsupportedType: String(localized: "The scan root is not a directory or supported link.", bundle: .module)
        case .rootReadFailed: String(localized: "The scan root could not be read.", bundle: .module)
        case .unknownSymlink: String(localized: "The Skill uses a symbolic link that cannot be trusted.", bundle: .module)
        case .symbolicLinkTargetUnavailable: String(localized: "The Skill link target is unavailable.", bundle: .module)
        case .symbolicLinkTargetUnsupported: String(localized: "The Skill link target is not a directory.", bundle: .module)
        case .candidatePermissionDenied: String(localized: "The Skill folder cannot be read.", bundle: .module)
        case .sourceChanged: String(localized: "The Skill changed while it was being inspected.", bundle: .module)
        case .missingSkillManifest: String(localized: "SKILL.md is missing.", bundle: .module)
        case .containerDirectory: String(localized: "This folder contains Skill subdirectories.", bundle: .module)
        case .invalidSkillManifest: String(localized: "SKILL.md is not valid UTF-8.", bundle: .module)
        case .unsupportedEntryType: String(localized: "The Skill contains an unsupported file type.", bundle: .module)
        case .unsafeContent: String(localized: "The Skill contains an unsafe path or link.", bundle: .module)
        case .resourceLimitExceeded: String(localized: "The Skill exceeds the safe import limits.", bundle: .module)
        case .candidateReadFailed: String(localized: "The Skill content could not be read.", bundle: .module)
        case .ambiguousLocalAssociation: String(localized: "This location is linked to more than one managed Skill.", bundle: .module)
        case .localAssociationDrift: String(localized: "This location no longer matches its managed Skill.", bundle: .module)
        case .ambiguousSource: String(localized: "The source metadata matches more than one managed Skill.", bundle: .module)
        case .ambiguousFingerprint: String(localized: "The content matches more than one managed Skill.", bundle: .module)
        case .evidenceConflict: String(localized: "The source and content point to different managed Skills.", bundle: .module)
        case .scopeSlugConflict: String(localized: "More than one Skill uses this name in the same scope.", bundle: .module)
        }
    }

    private func scopeText(_ scope: SkillDiscoveryScope) -> String {
        let adapter: String?
        if let adapterCode = scope.adapterCode {
            switch adapterCode {
            case SkillPlatform.codex.storageKey:
                adapter = String(localized: "Codex", bundle: .module)
            case SkillPlatform.claude.storageKey:
                adapter = String(localized: "Claude Code", bundle: .module)
            case SkillPlatform.opencode.storageKey:
                adapter = String(localized: "OpenCode", bundle: .module)
            case SkillPlatform.copilot.storageKey:
                adapter = String(localized: "GitHub Copilot", bundle: .module)
            default:
                adapter = adapterCode
            }
        } else {
            adapter = nil
        }
        switch scope.kind {
        case .global: return String(localized: "Global", bundle: .module)
        case .agent:
            return [adapter, scope.pathVariant].compactMap { $0 }.joined(separator: " · ")
        case .custom:
            return [String(localized: "Custom", bundle: .module), adapter, scope.pathVariant]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    private func scopeSummaryText(_ observation: SkillDiscoveryObservation) -> String {
        Array(Set(observation.roots.map { scopeText($0.scope) }))
            .sorted()
            .joined(separator: ", ")
    }

    private func actionTitleText(_ title: String) -> String {
        return switch title {
        case "Preview claim": String(localized: "Preview claim", bundle: .module)
        case "Preview independent import": String(localized: "Preview independent import", bundle: .module)
        case "Preview import": String(localized: "Preview import", bundle: .module)
        default: title
        }
    }

    private func unavailableTitleText(_ title: String) -> String {
        return switch title {
        case "Discovery unavailable": String(localized: "Discovery unavailable", bundle: .module)
        case "Discovery failed": String(localized: "Discovery failed", bundle: .module)
        default: title
        }
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
                Text(pending.preview.displayName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent {
                        Text(verbatim: actionNameText)
                    } label: {
                        Text("Action", bundle: .module)
                    }
                    LabeledContent {
                        Text(targetDescription)
                    } label: {
                        Text("Target", bundle: .module)
                    }
                    LabeledContent {
                        Text(verbatim: managedResultDescriptionText)
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
                        Text(verbatim: confirmButtonTitleText)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isImporting)
                .accessibilityLabel(Text(verbatim: model.isImporting
                    ? String(localized: "Import in progress", bundle: .module)
                    : confirmButtonTitleText))
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .interactiveDismissDisabled(model.isImporting)
    }

    private var title: String {
        pending.preview.action == .claimExisting ? "Confirm claim" : "Confirm import"
    }

    private var titleText: String {
        switch title {
        case "Confirm claim": String(localized: "Confirm claim", bundle: .module)
        case "Confirm import": String(localized: "Confirm import", bundle: .module)
        default: title
        }
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

    private var actionNameText: String {
        return switch actionName {
        case "Associate this local folder with an existing Skill":
            String(localized: "Associate this local folder with an existing Skill", bundle: .module)
        case "Import this local folder as a managed Skill":
            String(localized: "Import this local folder as a managed Skill", bundle: .module)
        default: actionName
        }
    }

    private var managedResultDescriptionText: String {
        return switch managedResultDescription {
        case "A local-origin record will be added to the matched Skill":
            String(localized: "A local-origin record will be added to the matched Skill", bundle: .module)
        case "Content will be copied into the SSOT and recorded in the database":
            String(localized: "Content will be copied into the SSOT and recorded in the database", bundle: .module)
        default: managedResultDescription
        }
    }

    private var confirmButtonTitleText: String {
        return switch confirmButtonTitle {
        case "Confirm claim": String(localized: "Confirm claim", bundle: .module)
        case "Confirm import": String(localized: "Confirm import", bundle: .module)
        default: confirmButtonTitle
        }
    }
}
