import Foundation
import Observation

enum CustomPathError: LocalizedError {
    case directoryNotFound
    case duplicatePath

    var errorDescription: String? {
        switch self {
        case .directoryNotFound:
            return "The selected directory does not exist."
        case .duplicatePath:
            return "This path has already been added."
        }
    }
}

@MainActor
@Observable final class CustomPathStore {
    private(set) var customPaths: [CustomSkillPath] = []
    private var persistence: JournaledSSOTWriter?

    func activate(using persistence: JournaledSSOTWriter) async throws {
        let records = try await persistence.loadCustomPaths()
        customPaths = records.map {
            CustomSkillPath(
                id: $0.id,
                url: $0.url,
                displayName: $0.displayName,
                addedAt: Date(timeIntervalSince1970: Double($0.addedAtMilliseconds) / 1_000)
            )
        }
        self.persistence = persistence
    }

    func addPath(_ url: URL) async throws {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw CustomPathError.directoryNotFound
        }

        guard !customPaths.contains(where: { $0.url == url }) else {
            throw CustomPathError.duplicatePath
        }

        let newPath = CustomSkillPath(url: url)
        try await persistence.insertCustomPath(newPath)
        customPaths.append(newPath)
    }

    func removePath(_ path: CustomSkillPath) async throws {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        try await persistence.removeCustomPath(id: path.id)
        customPaths.removeAll { $0.id == path.id }
    }
}
