import SwiftUI

struct ManagedClawdhubInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @Environment(RemoteSkillStore.self) private var remoteStore
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime
    @Environment(SkillResultCenter.self) private var resultCenter

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
                    ProgressView(String(localized: "Downloading and validating…", bundle: SkillsManagerLocalizationResources.bundle))
                }
                if let problem = model.problem {
                    Label(localizedManagedLocalImportProblem(problem), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let errorMessage {
                    Label {
                        Text(verbatim: errorMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
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
            Text("Install or Update Skill", bundle: SkillsManagerLocalizationResources.bundle)
                .font(.title.bold())
            Text(
                String(
                    localized: LocalizedStringResource(
            "Add \(skill.displayName) to the managed library or safely update it.",
            bundle: SkillsManagerLocalizationResources.bundle
        )
                )
            )
                .foregroundStyle(.secondary)
            Text(verbatim: sourceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(
                    String(
                        localized: LocalizedStringResource(
            "Source \(sourceSummary)",
            bundle: SkillsManagerLocalizationResources.bundle
        )
                    )
                ))
        }
    }

    private var sourceSummary: String {
        guard let version = skill.latestVersion else {
            return String(
                localized: LocalizedStringResource(
            "ClawHub · \(skill.slug)",
            bundle: SkillsManagerLocalizationResources.bundle
        )
            )
        }
        return String(
            localized: LocalizedStringResource(
            "ClawHub · \(skill.slug) · \(version)",
            bundle: SkillsManagerLocalizationResources.bundle
        )
        )
    }

    private var actions: some View {
        HStack {
            Button {
                cancelAndDismiss()
            } label: {
                Text("Cancel", bundle: SkillsManagerLocalizationResources.bundle)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isExecuting || model.isFinalizing)

            Spacer()

            Button {
                prepareInstall()
            } label: {
                Text("Review…", bundle: SkillsManagerLocalizationResources.bundle)
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
                if let problem = model.problem {
                    resultCenter.publishInstallFailure(
                        localizedManagedLocalImportProblem(problem),
                        subject: .clawHub(skill.id)
                    )
                    await cleanupCandidate()
                }
            } catch is CancellationError {
                return
            } catch {
                model.reset()
                let message = localizedManagedInstallError(error)
                errorMessage = message
                resultCenter.publishInstallFailure(message, subject: .clawHub(skill.id))
            }
        }
    }

    private func confirmInstall() {
        activeTask?.cancel()
        activeTask = Task {
            isInstalling = true
            defer { isInstalling = false }
            await model.confirm {
                if let result = model.result {
                    didInstall = true
                    resultCenter.publishInstallResult(result, subject: .clawHub(skill.id))
                }
                await store.loadSkills()
                await discoveryModel.refresh()
                await cleanupCandidate()
            }
            if let problem = model.problem {
                let message = localizedManagedLocalImportProblem(problem)
                errorMessage = message
                resultCenter.publishInstallFailure(message, subject: .clawHub(skill.id))
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: ManagedLocalImportResult) -> some View {
        let presentation = managedInstallResultPresentation(result)
        ContentUnavailableView(
            localizedManagedInstallResultTitle(result.status),
            systemImage: presentation.systemImage,
            description: Text(verbatim: localizedManagedInstallResultMessage(result))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Close", bundle: SkillsManagerLocalizationResources.bundle)
            }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("install.result.close")
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
