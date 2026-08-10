import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

private struct ImportCandidate {
    let displayName: String
    let payload: SkillImportWorker.ImportCandidatePayload
}

struct ImportSkillView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillStore.self) private var store
    @Environment(SkillDiscoveryViewModel.self) private var discoveryModel
    @Environment(LibraryRuntimeState.self) private var libraryRuntime
    @State private var model = ManagedLocalImportViewModel()
    @State private var archiveModel = ManagedArchiveImportViewModel()
    @State private var showingPicker = false
    @State private var candidate: ImportCandidate?
    @State private var status: Status = .idle
    @State private var errorMessage = ""
    @State private var distributionMode: ManagedInstallDistributionMode = .global
    @State private var selectedAgents: Set<SkillPlatform> = [.codex]
    @State private var activeTask: Task<Void, Never>?
    @State private var operationToken = UUID()
    @State private var archiveSession: SkillImportWorker.ArchiveSession?
    private let importWorker = SkillImportWorker()

    private enum Status {
        case idle
        case validating
        case valid
        case invalid
        case preparing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            Spacer()
            actions
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.folder, .zip],
            allowsMultipleSelection: false
        ) { handlePick($0) }
        .sheet(item: previewBinding) { preview in
            ManagedLocalImportPreviewView(
                preview: preview,
                onConfirm: confirmImport
            )
            .environment(model)
        }
        .task {
            model.activate(writer: store.persistence)
            archiveModel.activate(writer: store.persistence)
        }
#if SKILLS_MANAGER_UI_TEST
        .task {
            let fixture = SkillsManagerUIFixtureRuntime.current()
            guard fixture.isAdmitted,
                  fixture.profile == .baseline,
                  FileManager.default.fileExists(atPath: fixture.archiveURL.path) else { return }
            handlePick(.success([fixture.archiveURL]))
        }
#endif
        .onChange(of: libraryRuntime.readiness) { _, _ in
            if !model.isWorking {
                model.activate(writer: store.persistence)
            }
            if !archiveModel.isWorking {
                archiveModel.activate(writer: store.persistence)
            }
        }
        .onDisappear {
            cancelAndCleanup()
        }
        .interactiveDismissDisabled(model.isWorking || archiveModel.isWorking)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import Skill", bundle: .module)
                .font(.title.bold())
            Text("Choose a Skill folder or zip, then add it to the managed library.", bundle: .module)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if archiveSession != nil {
            ManagedArchiveImportView(
                model: archiveModel,
                onPrepare: prepareArchiveImport,
                onConfirm: confirmArchiveImport
            )
        } else if model.result != nil {
            resultState
        } else {
            switch status {
            case .idle:
                emptyState
            case .validating:
                ProgressView(localized("Validating…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .valid:
                candidatePreview
            case .invalid:
                invalidState
            case .preparing:
                ProgressView(localized("Preparing import preview…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            localized("Pick a folder or zip"),
            systemImage: "tray.and.arrow.down",
            description: Text("We’ll verify it contains a SKILL.md and show a preview.", bundle: .module)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var invalidState: some View {
        ContentUnavailableView(
            localized("Unable to import"),
            systemImage: "xmark.octagon",
            description: Text(errorMessage)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultState: some View {
        let presentation = resultPresentation
        return VStack {
            ContentUnavailableView(
                localized(presentation.title),
                systemImage: presentation.systemImage,
                description: resultMessage
            )
            if model.isFinalizing {
                ProgressView(localized("Refreshing library…"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultPresentation: (title: String, systemImage: String) {
        guard let result = model.result else {
            return ("Import status unavailable", "exclamationmark.triangle")
        }
        switch result.status {
        case .distributed:
            return ("Imported and enabled", "checkmark.seal")
        case .noDistributionChanges:
            return ("Imported", "checkmark.seal")
        case .managedUndistributed:
            return ("Imported but not enabled", "exclamationmark.triangle")
        case .managedDistributionIndeterminate:
            return ("Distribution needs attention", "wrench.and.screwdriver")
        case .managementIndeterminate:
            return ("Import needs attention", "wrench.and.screwdriver")
        case .alreadyManaged:
            return ("Already managed", "checkmark.circle")
        case .updateRequired:
            return ("Update required", "arrow.triangle.2.circlepath")
        case .updated:
            return ("Updated", "checkmark.seal")
        case .updatedDistributionNeedsAttention:
            return ("Updated; distribution needs attention", "exclamationmark.triangle")
        case .updateIndeterminate:
            return ("Update needs confirmation", "wrench.and.screwdriver")
        }
    }

    private var resultMessage: Text {
        guard let result = model.result else {
            return Text("Refresh the library.", bundle: .module)
        }
        switch result.status {
        case .distributed:
            return Text(
                "\(result.displayName) is managed and available to the selected Agents.",
                bundle: .module
            )
        case .noDistributionChanges:
            return Text(
                "\(result.displayName) is managed; no distribution changes were needed.",
                bundle: .module
            )
        case .managedUndistributed:
            return Text(
                "\(result.displayName) is safe in the managed library, but distribution was not applied.",
                bundle: .module
            )
        case .managedDistributionIndeterminate:
            return Text(
                "\(result.displayName) is managed, but its distribution state must be confirmed or repaired.",
                bundle: .module
            )
        case .managementIndeterminate:
            return Text(
                "The import state for \(result.displayName) must be confirmed or repaired before retrying.",
                bundle: .module
            )
        case .alreadyManaged:
            return Text("\(result.displayName) is already in the managed library.", bundle: .module)
        case .updateRequired:
            return Text("\(result.displayName) differs from the managed version.", bundle: .module)
        case .updated:
            return Text("\(result.displayName) was updated.", bundle: .module)
        case .updatedDistributionNeedsAttention:
            return Text(
                "Refresh \(result.displayName)'s distribution from its details.",
                bundle: .module
            )
        case .updateIndeterminate:
            return Text("Confirm or repair the managed library before retrying.", bundle: .module)
        }
    }

    private var candidatePreview: some View {
        guard let candidate else { return AnyView(EmptyView()) }
        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.displayName)
                            .font(.title2.bold())
                        Text(candidate.payload.rootURL.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    distributionSelection
                    if let problem = model.problem {
                        Label(problem.localizedDescription, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Markdown(candidate.payload.markdown)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
        )
    }

    private var distributionSelection: some View {
        ManagedInstallScopePicker(
            mode: $distributionMode,
            selectedAgents: $selectedAgents,
            isDisabled: model.isWorking
        )
    }

    @ViewBuilder
    private var actions: some View {
        if archiveSession != nil {
            archiveActions
        } else if model.result != nil {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Close", bundle: .module)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking)
            }
        } else {
            HStack {
                Button {
                    cancelAndDismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isWorking)

                Spacer()

                Button {
                    showingPicker = true
                } label: {
                    Text("Choose…", bundle: .module)
                }
                .disabled(model.isWorking)

                Button {
                    prepareImport()
                } label: {
                    Text("Review Import…", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPrepareImport)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var archiveActions: some View {
        HStack {
            if archiveModel.state == .completed {
                Button {
                    cancelAndDismiss()
                } label: {
                    Text("Close", bundle: .module)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(archiveModel.isWorking)
            } else {
                Button {
                    cancelAndDismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(archiveModel.isWorking)
                Spacer()
                Button {
                    showingPicker = true
                } label: {
                    Text("Choose…", bundle: .module)
                }
                    .disabled(archiveModel.isWorking)
            }
        }
    }

    private var canPrepareImport: Bool {
        status == .valid
            && model.result == nil
            && model.isAvailable
            && !model.isWorking
            && (distributionMode == .global || !selectedAgents.isEmpty)
    }

    private var previewBinding: Binding<ManagedLocalImportPreview?> {
        Binding(
            get: { model.preview },
            set: { if $0 == nil { model.cancelPreview() } }
        )
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        let previousTask = activeTask
        previousTask?.cancel()
        switch result {
        case .failure(let error):
            let token = UUID()
            operationToken = token
            activeTask = Task {
                await previousTask?.value
                guard operationToken == token else { return }
                await cleanupCandidate()
                status = .invalid
                errorMessage = error.localizedDescription
            }
        case .success(let urls):
            guard let url = urls.first else {
                let token = UUID()
                operationToken = token
                activeTask = Task {
                    await previousTask?.value
                    guard operationToken == token else { return }
                    await cleanupCandidate()
                    status = .idle
                }
                return
            }
            let token = UUID()
            operationToken = token
            activeTask = Task {
                await previousTask?.value
                guard operationToken == token else { return }
                await validate(url: url, token: token)
            }
        }
    }

    private func validate(url: URL, token: UUID) async {
        guard operationToken == token else { return }
        status = .validating
        errorMessage = ""
        await cleanupCandidate()

        let resolved = url.standardizedFileURL
        let fileValues = try? resolved.resourceValues(forKeys: [.isDirectoryKey])
        guard operationToken == token, !Task.isCancelled else { return }

        do {
            if fileValues?.isDirectory == true {
                let payload = try await importWorker.validateFolder(resolved)
                guard operationToken == token, !Task.isCancelled else { return }
                candidate = ImportCandidate(
                    displayName: formatTitle(payload.skillName),
                    payload: payload
                )
                model.reset()
                archiveSession = nil
                archiveModel.reset()
                status = .valid
            } else if resolved.pathExtension.lowercased() == "zip" {
                let session = try await importWorker.validateZipSession(resolved)
                guard operationToken == token, !Task.isCancelled else {
                    await importWorker.cleanupArchiveSession(session)
                    return
                }
                archiveSession = session
                archiveModel.reset()
                archiveModel.configure(session: session)
                model.reset()
                status = .valid
            } else {
                throw SkillImportValidationError.contentRejected("Select a folder or .zip file.")
            }
        } catch is CancellationError {
            return
        } catch {
            guard operationToken == token else { return }
            status = .invalid
            errorMessage = error.localizedDescription
        }
    }

    private func prepareImport() {
        guard let candidate else { return }
        let token = operationToken
        status = .preparing
        activeTask?.cancel()
        activeTask = Task {
            await model.prepare(
                candidate: candidate.payload,
                displayName: candidate.displayName,
                scope: distributionMode == .global ? .global : .agents(selectedAgents)
            )
            guard operationToken == token else { return }
            if let problem = model.problem {
                errorMessage = problem.localizedDescription
                status = .valid
            } else {
                status = .valid
            }
        }
    }

    private func prepareArchiveImport(_ scope: ManagedLocalImportScope) {
        guard archiveSession != nil, !archiveModel.isWorking else { return }
        let token = operationToken
        activeTask?.cancel()
        activeTask = Task {
            await archiveModel.prepare(scope: scope)
            guard operationToken == token else { return }
        }
    }

    private func confirmArchiveImport() {
        guard archiveSession != nil, !archiveModel.isWorking else { return }
        let token = operationToken
        activeTask?.cancel()
        activeTask = Task {
            await archiveModel.confirm {
                await finalizeArchiveImport()
            }
            guard operationToken == token else { return }
        }
    }

    private func confirmImport() {
        let token = operationToken
        activeTask?.cancel()
        activeTask = Task {
            await model.confirm {
                await store.loadSkills()
                await discoveryModel.refresh()
                await cleanupCandidate()
            }
            guard operationToken == token else { return }
            if let problem = model.problem {
                errorMessage = problem.localizedDescription
            }
        }
    }

    private func cancelAndDismiss() {
        let task = activeTask
        activeTask = nil
        operationToken = UUID()
        let temporaryRoot = candidate?.payload.temporaryRoot
        let session = archiveSession
        candidate = nil
        archiveSession = nil
        Task {
            await importWorker.cleanupTemporaryRoot(
                temporaryRoot,
                afterCancelling: task
            )
            await importWorker.cleanupArchiveSession(session)
            dismiss()
        }
    }

    private func cancelAndCleanup() {
        let task = activeTask
        activeTask = nil
        operationToken = UUID()
        let temporaryRoot = candidate?.payload.temporaryRoot
        let session = archiveSession
        candidate = nil
        archiveSession = nil
        Task {
            await importWorker.cleanupTemporaryRoot(
                temporaryRoot,
                afterCancelling: task
            )
            await importWorker.cleanupArchiveSession(session)
        }
    }

    private func cleanupCandidate() async {
        let temporaryRoot = candidate?.payload.temporaryRoot
        let session = archiveSession
        candidate = nil
        archiveSession = nil
        if let temporaryRoot {
            await importWorker.cleanupTemporaryRoot(temporaryRoot)
        }
        await importWorker.cleanupArchiveSession(session)
    }

    private func finalizeArchiveImport() async {
        await store.loadSkills()
        await discoveryModel.refresh()
    }

    private func localized(_ value: String) -> String {
        String(localized: String.LocalizationValue(value), bundle: .module)
    }
}
