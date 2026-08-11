import Foundation
import Observation

enum CustomPathError: LocalizedError {
    case directoryNotFound
    case duplicatePath
    case invalidMode

    var errorDescription: String? {
        switch self {
        case .directoryNotFound:
            return "The selected directory does not exist."
        case .duplicatePath:
            return "This path has already been added."
        case .invalidMode:
            return "The selected custom path mode is invalid."
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
                addedAt: Date(timeIntervalSince1970: Double($0.addedAtMilliseconds) / 1_000),
                mode: $0.mode
            )
        }
        self.persistence = persistence
    }

    func addPath(
        _ url: URL,
        mode: CustomSkillPathMode = .project
    ) async throws {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CustomPathError.directoryNotFound
        }

        let normalized = try LegacyCustomPathURLNormalizer.normalize(url.absoluteString)
        guard !customPaths.contains(where: {
            (try? LegacyCustomPathURLNormalizer.normalize($0.url.absoluteString))?.key == normalized.key
        }) else {
            throw CustomPathError.duplicatePath
        }

        let newPath = CustomSkillPath(url: url, mode: mode)
        try await persistence.insertCustomPath(newPath)
        customPaths.append(newPath)
    }

    func removePath(_ path: CustomSkillPath) async throws {
        guard let persistence else { throw LibraryPersistenceError.runtimeNotReady }
        try await persistence.removeCustomPath(id: path.id)
        customPaths.removeAll { $0.id == path.id }
    }
}
