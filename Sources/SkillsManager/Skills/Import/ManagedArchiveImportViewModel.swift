import Foundation
import Observation

nonisolated enum ManagedArchiveImportState: Equatable, Sendable {
    case idle
    case selecting
    case preparing
    case ready
    case executing
    case completed
}

nonisolated struct ManagedArchiveImportPreviewItem: Sendable, Identifiable {
    let candidate: SkillImportWorker.ArchiveCandidate
    let preview: ManagedLocalImportPreview?
    let reason: String?

    var id: SkillImportWorker.ArchiveCandidateID { candidate.id }
}

nonisolated enum ManagedArchiveImportManagementResult: Equatable, Sendable {
    case imported(ManagedLocalImportResultStatus)
    case skipped(String)
    case failed(String)
}

nonisolated struct ManagedArchiveImportResultItem: Sendable, Identifiable {
    let id: SkillImportWorker.ArchiveCandidateID
    let canonicalSubpath: String
    let displayName: String
    let management: ManagedArchiveImportManagementResult
}

nonisolated struct ManagedArchiveImportSummary: Equatable, Sendable {
    let total: Int
    let imported: Int
    let skipped: Int
    let failed: Int

    static let empty = Self(items: [])

    init(items: [ManagedArchiveImportResultItem]) {
        total = items.count
        imported = items.count {
            if case .imported = $0.management { true } else { false }
        }
        skipped = items.count {
            if case .skipped = $0.management { true } else { false }
        }
        failed = items.count {
            if case .failed = $0.management { true } else { false }
        }
    }
}

@MainActor
@Observable final class ManagedArchiveImportViewModel {
    private(set) var state: ManagedArchiveImportState = .idle
    private(set) var session: SkillImportWorker.ArchiveSession?
    private(set) var selectedIDs: Set<SkillImportWorker.ArchiveCandidateID> = []
    private(set) var previewItems: [ManagedArchiveImportPreviewItem] = []
    private(set) var resultItems: [ManagedArchiveImportResultItem] = []
    private(set) var summary = ManagedArchiveImportSummary.empty
    private(set) var errorMessage: String?
    private(set) var generation: UInt64 = 0

    private var service: ManagedInstallService?
    private var activeGeneration: UInt64 = 0

    var candidates: [SkillImportWorker.ArchiveCandidate] { session?.candidates ?? [] }
    var selectedCount: Int { selectedIDs.count }
    var availableCandidateCount: Int { candidates.count(where: \.isImportable) }
    var isWorking: Bool { state == .preparing || state == .executing }
    var hasBlockedDistribution: Bool {
        previewItems.contains { $0.preview?.plan.status == .blocked }
    }
    var canPrepare: Bool {
        state == .selecting && !selectedIDs.isEmpty && service != nil
    }
    var canConfirm: Bool {
        state == .ready && !previewItems.isEmpty && generation == activeGeneration
    }

    func activate(writer: JournaledSSOTWriter?) {
        generation &+= 1
        guard let writer else {
            service = nil
            errorMessage = String(localized: "The managed library session is unavailable.", bundle: .module)
            return
        }
        service = ManagedInstallService(dependencies: .live(writer: writer))
    }

    func activate(dependencies: ManagedInstallDependencies) {
        service = ManagedInstallService(dependencies: dependencies)
    }

    func configure(session: SkillImportWorker.ArchiveSession) {
        guard !isWorking else { return }
        self.session = session
        generation &+= 1
        activeGeneration = generation
        selectedIDs = Set(session.candidates.filter(\.isImportable).map(\.id))
        previewItems = []
        resultItems = []
        summary = .empty
        errorMessage = nil
        state = .selecting
    }

    func isSelected(_ id: SkillImportWorker.ArchiveCandidateID) -> Bool {
        selectedIDs.contains(id)
    }

    func toggleSelection(_ id: SkillImportWorker.ArchiveCandidateID) {
        guard state == .selecting,
              let candidate = candidates.first(where: { $0.id == id }),
              candidate.isImportable else { return }
        if !selectedIDs.insert(id).inserted {
            selectedIDs.remove(id)
        }
    }

    func selectAllSafe() {
        guard state == .selecting else { return }
        selectedIDs = Set(candidates.filter(\.isImportable).map(\.id))
    }

    func clearSelection() {
        guard state == .selecting else { return }
        selectedIDs.removeAll()
    }

    func prepare(scope: ManagedLocalImportScope) async {
        guard canPrepare, let service, let session else { return }
        let expectedGeneration = generation
        state = .preparing
        errorMessage = nil
        previewItems = []
        do {
            try session.requireCurrent()
        } catch {
            errorMessage = String(localized: "The archive preview is no longer available.", bundle: .module)
            state = .selecting
            return
        }

        let selected = session.candidates.filter { selectedIDs.contains($0.id) }
        for candidate in selected {
            guard !Task.isCancelled else {
                previewItems = []
                state = .selecting
                return
            }
            guard let payload = candidate.payload else {
                previewItems.append(.init(
                    candidate: candidate,
                    preview: nil,
                    reason: candidate.blockedReason
                        ?? String(localized: "This candidate is not importable.", bundle: .module)
                ))
                continue
            }
            do {
                try Task.checkCancellation()
                let preview = try await service.prepareArchive(
                    candidate: payload,
                    displayName: candidate.displayName,
                    scope: scope
                )
                try Task.checkCancellation()
                previewItems.append(.init(candidate: candidate, preview: preview, reason: nil))
            } catch is CancellationError {
                previewItems = []
                state = .selecting
                return
            } catch {
                previewItems.append(.init(
                    candidate: candidate,
                    preview: nil,
                    reason: Self.message(for: error)
                ))
            }
        }
        guard !Task.isCancelled,
              state == .preparing,
              generation == expectedGeneration else { return }
        activeGeneration = expectedGeneration
        state = .ready
    }

    func cancelPreview() {
        guard !isWorking else { return }
        previewItems = []
        errorMessage = nil
        state = session == nil ? .idle : .selecting
    }

    func confirm(finalize: @MainActor () async -> Void = {}) async {
        guard canConfirm, let service, let session else { return }
        state = .executing
        errorMessage = nil
        resultItems = []
        summary = .empty

        for item in previewItems {
            guard !Task.isCancelled else {
                state = .ready
                return
            }
            let result: ManagedArchiveImportResultItem
            guard let preview = item.preview else {
                result = ManagedArchiveImportResultItem(
                    id: item.id,
                    canonicalSubpath: item.candidate.canonicalSubpath,
                    displayName: item.candidate.displayName,
                    management: .skipped(
                        item.reason ?? String(localized: "This candidate was skipped.", bundle: .module)
                    )
                )
                resultItems.append(result)
                summary = ManagedArchiveImportSummary(items: resultItems)
                continue
            }
            do {
                try Task.checkCancellation()
                try session.requireCurrent()
                guard let payload = item.candidate.payload else {
                    throw ManagedLocalImportProblem.invalidCandidate
                }
                try payload.requireSourceUnchanged()
                let managed = try await service.execute(preview.token)
                try Task.checkCancellation()
                result = ManagedArchiveImportResultItem(
                    id: item.id,
                    canonicalSubpath: item.candidate.canonicalSubpath,
                    displayName: item.candidate.displayName,
                    management: .imported(managed.status)
                )
            } catch is CancellationError {
                state = .ready
                return
            } catch {
                result = ManagedArchiveImportResultItem(
                    id: item.id,
                    canonicalSubpath: item.candidate.canonicalSubpath,
                    displayName: item.candidate.displayName,
                    management: .failed(Self.message(for: error))
                )
            }
            resultItems.append(result)
            summary = ManagedArchiveImportSummary(items: resultItems)
        }

        guard !Task.isCancelled else {
            state = .ready
            return
        }
        await finalize()
        guard !Task.isCancelled else {
            state = .ready
            return
        }
        state = .completed
    }

    func reset() {
        guard !isWorking else { return }
        generation &+= 1
        session = nil
        selectedIDs = []
        previewItems = []
        resultItems = []
        summary = .empty
        errorMessage = nil
        state = .idle
    }

    @MainActor static func message(for error: Error) -> String {
        if let error = error as? ManagedLocalImportProblem {
            return localizedManagedLocalImportProblem(error)
        }
        if let error = error as? SkillImportValidationError {
            return error.localizedDescription
        }
        return error.localizedDescription
    }
}
