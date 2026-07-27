import SwiftUI

struct ManagedClawdhubInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime

    let skill: RemoteSkill
    @Binding var isInstalling: Bool
    @Binding var didInstall: Bool
    @Binding var errorMessage: String?

    @State private var model = ManagedLocalImportViewModel()
    @State private var distributionMode: ManagedInstallDistributionMode = .global
    @State private var selectedAgents: Set<SkillPlatform> = [.codex]
    @State private var candidate: SkillImportWorker.ImportCandidatePayload?
    @State private var activeTask: Task<Void, Never>?
    @State private var isDownloading = false
    private let importWorker = SkillImportWorker()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let result = model.result {
                resultView(result)
            } else {
                ManagedInstallScopePicker(
                    mode: $distributionMode,
                    selectedAgents: $selectedAgents,
                    isDisabled: isWorking
                )
                if isDownloading {
                    ProgressView("Downloading and validating…")
                }
                if let problem = model.problem {
                    Label(problem.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                actions
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 400)
        .sheet(item: previewBinding) { preview in
            ManagedLocalImportPreviewView(
                preview: preview,
                onConfirm: confirmInstall
            )
            .environment(model)
        }
        .task {
            model.activate(writer: store.persistence)
        }
        .onChange(of: libraryRuntime.readiness) { _, _ in
            if !isWorking {
                model.activate(writer: store.persistence)
            }
        }
        .onDisappear {
            cancelAndCleanup()
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Install Skill")
                .font(.title.bold())
            Text("Add \(skill.displayName) to the managed library, then enable it.")
                .foregroundStyle(.secondary)
            Text(sourceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Source \(sourceSummary)")
        }
    }

    private var sourceSummary: String {
        guard let version = skill.latestVersion else {
            return "Clawdhub · \(skill.slug)"
        }
        return "Clawdhub · \(skill.slug) · \(version)"
    }

    private var actions: some View {
        HStack {
            Button("Cancel") {
                cancelAndDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isExecuting || model.isFinalizing)

            Spacer()

            Button("Review Install…") {
                prepareInstall()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPrepare)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var canPrepare: Bool {
        model.isAvailable
            && !isWorking
            && (distributionMode == .global || !selectedAgents.isEmpty)
    }

    private var isWorking: Bool {
        isDownloading || model.isWorking
    }

    private var previewBinding: Binding<ManagedLocalImportPreview?> {
        Binding(
            get: { model.preview },
            set: { if $0 == nil { model.cancelPreview() } }
        )
    }

    private func prepareInstall() {
        activeTask?.cancel()
        activeTask = Task {
            await cleanupCandidate()
            model.reset()
            errorMessage = nil
            isDownloading = true
            isInstalling = true
            didInstall = false
            defer {
                isDownloading = false
                isInstalling = false
            }
            do {
                let archive = try await remoteStore.client.download(
                    skill.slug,
                    skill.latestVersion
                )
                let payload: SkillImportWorker.ImportCandidatePayload
                do {
                    payload = try await importWorker.validateZip(archive.url)
                } catch {
                    cleanup(archive)
                    throw error
                }
                cleanup(archive)
                guard !Task.isCancelled else {
                    if let temporaryRoot = payload.temporaryRoot {
                        await importWorker.cleanupTemporaryRoot(temporaryRoot)
                    }
                    return
                }
                candidate = payload
                await model.prepareClawdhub(
                    candidate: payload,
                    skill: skill,
                    scope: distributionMode == .global ? .global : .agents(selectedAgents)
                )
                if model.problem != nil {
                    await cleanupCandidate()
                }
            } catch is CancellationError {
                return
            } catch {
                model.reset()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmInstall() {
        activeTask?.cancel()
        activeTask = Task {
            isInstalling = true
            defer { isInstalling = false }
            await model.confirm {
                await store.loadSkills()
                await discoveryModel.refresh()
                await cleanupCandidate()
            }
            if model.result != nil {
                didInstall = true
            } else if let problem = model.problem {
                errorMessage = problem.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: ManagedLocalImportResult) -> some View {
        let presentation = resultPresentation(result)
        ContentUnavailableView(
            presentation.title,
            systemImage: presentation.systemImage,
            description: Text(presentation.message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func resultPresentation(
        _ result: ManagedLocalImportResult
    ) -> (title: String, systemImage: String, message: String) {
        switch result.status {
        case .distributed:
            ("Installed and enabled", "checkmark.seal", "\(result.displayName) is ready.")
        case .noDistributionChanges:
            ("Installed", "checkmark.seal", "\(result.displayName) is managed.")
        case .managedUndistributed:
            (
                "Installed but not enabled",
                "exclamationmark.triangle",
                "\(result.displayName) is managed; resolve its distribution conflict from details."
            )
        case .managedDistributionIndeterminate:
            (
                "Distribution needs attention",
                "wrench.and.screwdriver",
                "\(result.displayName) is managed, but its Agent state must be confirmed."
            )
        case .managementIndeterminate:
            (
                "Install needs attention",
                "wrench.and.screwdriver",
                "Confirm or repair the managed library before retrying."
            )
        case .alreadyManaged:
            (
                "Already managed",
                "checkmark.circle",
                "Use the Skill details to change where \(result.displayName) is enabled."
            )
        case .updateRequired:
            (
                "Update required",
                "arrow.triangle.2.circlepath",
                "Clawdhub has different content or a different version. No files were changed."
            )
        }
    }

    private func cancelAndDismiss() {
        let task = activeTask
        activeTask = nil
        let temporaryRoot = candidate?.temporaryRoot
        candidate = nil
        Task {
            await importWorker.cleanupTemporaryRoot(
                temporaryRoot,
                afterCancelling: task
            )
            dismiss()
        }
    }

    private func cancelAndCleanup() {
        let task = activeTask
        activeTask = nil
        let temporaryRoot = candidate?.temporaryRoot
        candidate = nil
        Task {
            await importWorker.cleanupTemporaryRoot(
                temporaryRoot,
                afterCancelling: task
            )
        }
    }

    private func cleanupCandidate() async {
        let temporaryRoot = candidate?.temporaryRoot
        candidate = nil
        if let temporaryRoot {
            await importWorker.cleanupTemporaryRoot(temporaryRoot)
        }
    }

    private func cleanup(_ archive: DownloadedSkillArchive) {
        do {
            try archive.removeIfOwned()
        } catch {
            NSLog(
                "Skills Manager preserved an unverified downloaded archive at %@: %@",
                archive.url.path,
                error.localizedDescription
            )
        }
    }
}
