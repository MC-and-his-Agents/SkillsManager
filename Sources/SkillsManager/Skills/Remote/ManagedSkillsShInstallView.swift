import SwiftUI

struct ManagedSkillsShInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime

    let item: SkillsShSearchItem

    @State private var model = ManagedLocalImportViewModel()
    @State private var distributionMode: ManagedInstallDistributionMode = .global
    @State private var selectedAgents: Set<SkillPlatform> = [.codex]
    @State private var candidate: SkillImportWorker.ImportCandidatePayload?
    @State private var activeTask: Task<Void, Never>?
    @State private var isResolving = false
    @State private var errorMessage: String?

    private let client = SkillsShGitHubSourceClient.live()
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
                if isResolving {
                    ProgressView("Resolving and validating GitHub source…")
                }
                if let problem = model.problem {
                    problemLabel(problem.localizedDescription)
                } else if let errorMessage {
                    problemLabel(errorMessage)
                }
                Spacer()
                actions
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
        .sheet(item: previewBinding) { preview in
            ManagedLocalImportPreviewView(preview: preview, onConfirm: confirmInstall)
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
            Text("Resolve and Install Skill")
                .font(.title.bold())
            Text(
                "Skills Manager will verify \(item.source), find one matching SKILL.md, "
                    + "and pin the install to an immutable GitHub commit."
            )
            .foregroundStyle(.secondary)
            Label(
                "Experimental skills.sh index; GitHub resolution may be unavailable or rate limited.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Cancel") {
                cancelAndDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isExecuting || model.isFinalizing)

            Spacer()

            Button("Resolve and Review…") {
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
        isResolving || model.isWorking
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
            isResolving = true
            defer { isResolving = false }
            do {
                let resolved = try await client.resolve(item.id, item.source, item.skillID)
                let downloaded = try await client.download(resolved)
                try Task.checkCancellation()
                let archive = try await Task.detached {
                    try persistDownloadedSkillArchive(data: downloaded.data)
                }.value
                let payload: SkillImportWorker.ImportCandidatePayload
                do {
                    payload = try await importWorker.validateZip(
                        archive.url,
                        repositorySubpath: resolved.subpath,
                        expectedBlobs: try resolved.blobs.map {
                            guard let byteCount = UInt64(exactly: $0.size) else {
                                throw SkillsShGitHubSourceError.contractChanged
                            }
                            return try SafeSkillArchive.RepositoryBlobExpectation(
                                relativePath: $0.relativePath,
                                mode: $0.mode,
                                byteCount: byteCount,
                                gitBlobSHA: $0.gitBlobSHA
                            )
                        }
                    )
                } catch {
                    try? archive.removeIfOwned()
                    throw error
                }
                do {
                    try archive.removeIfOwned()
                } catch {
                    if let temporaryRoot = payload.temporaryRoot {
                        await importWorker.cleanupTemporaryRoot(temporaryRoot)
                    }
                    throw error
                }
                guard !Task.isCancelled else {
                    if let temporaryRoot = payload.temporaryRoot {
                        await importWorker.cleanupTemporaryRoot(temporaryRoot)
                    }
                    return
                }
                candidate = payload
                let revision = try SourceRevision(resolved.commitSHA)
                let sourceInput = ManagedSourceInstallInput(
                    displayName: item.name,
                    distributionSlug: resolved.defaultDistributionSlug,
                    repositoryURL: resolved.repositoryURL,
                    subpath: resolved.subpath,
                    revision: revision,
                    downloadURL: try PublicDownloadURL(resolved.archiveURL.absoluteString),
                    alias: try ProviderAliasIdentity(
                        provider: "skills.sh",
                        identifier: resolved.providerAliasIdentifier
                    ),
                    refreshHead: {
                        try SourceRevision(try await client.currentCommitSHA(resolved))
                    }
                )
                await model.prepareSourceBacked(
                    candidate: payload,
                    sourceInput: sourceInput,
                    scope: distributionMode == .global ? .global : .agents(selectedAgents)
                )
                if model.problem != nil {
                    await cleanupCandidate()
                }
            } catch {
                if Task.isCancelled { return }
                model.reset()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmInstall() {
        activeTask?.cancel()
        activeTask = Task {
            await model.confirm {
                await store.loadSkills()
                await discoveryModel.refresh()
                await cleanupCandidate()
            }
            if let problem = model.problem {
                errorMessage = problem.localizedDescription
            }
        }
    }

    private func problemLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resultView(_ result: ManagedLocalImportResult) -> some View {
        let presentation = managedInstallResultPresentation(result)
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

    private func cancelAndDismiss() {
        cancelAndCleanup()
        dismiss()
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
}

nonisolated func persistDownloadedSkillArchive(
    data: Data
) throws -> DownloadedSkillArchive {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "skillsmanager-skillssh-\(UUID().uuidString.lowercased()).zip"
    )
    do {
        try data.write(to: url, options: [.atomic])
        return try DownloadedSkillArchive.takeOwnership(of: url)
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}
