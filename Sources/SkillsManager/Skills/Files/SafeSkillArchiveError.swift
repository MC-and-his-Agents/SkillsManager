import Foundation

nonisolated enum SafeSkillArchiveError: LocalizedError, Equatable {
    case invalidArchive, invalidDestination, destinationNotEmpty
    case unsafePath(String), pathCollision(String, String), unsupportedEntryType(String)
    case tooManyEntries, tooManyFiles, tooManyDirectories, pathTooDeep(String)
    case fileTooLarge(String), archiveTooLarge
    case invalidChecksum(String), invalidSize(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "The zip archive is invalid or contains an unsupported entry type."
        case .invalidDestination, .destinationNotEmpty: "The archive staging directory is unsafe or not empty."
        case .unsafePath(let path): "The archive contains an unsafe path: \(path)"
        case .pathCollision(let first, let second): "The archive contains conflicting paths: \(first) and \(second)"
        case .unsupportedEntryType(let path): "The archive contains a link or unsupported entry: \(path)"
        case .tooManyEntries: "The archive contains too many entries."
        case .tooManyFiles: "The archive contains too many files."
        case .tooManyDirectories: "The archive contains too many directories."
        case .pathTooDeep(let path): "The archive contains a path that is too deep: \(path)"
        case .fileTooLarge(let path): "The archive contains a file that is too large: \(path)"
        case .archiveTooLarge: "The archive exceeds the allowed size."
        case .invalidChecksum(let path), .invalidSize(let path):
            "The archive entry failed integrity validation: \(path)"
        }
    }
}
