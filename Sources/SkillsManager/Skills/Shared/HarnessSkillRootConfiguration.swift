import Darwin
import Foundation

nonisolated enum HarnessSkillRootResolutionStatus: String, Codable, Hashable, Sendable {
    case `default`
    case configured
    case environmentHint
    case environmentUnavailable
    case unavailable
    case permissionDenied
    case changed
    case unsupported
    case conflict
}

nonisolated enum HarnessSkillRootConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unavailable
    case permissionDenied
    case unsupportedType
    case conflictingRoot
    case invalidStoredIdentity
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The harness Skill root must be an absolute local directory."
        case .unavailable:
            "The harness Skill root is unavailable. Check the external volume and try again."
        case .permissionDenied:
            "The harness Skill root cannot be read because permission was denied."
        case .unsupportedType:
            "The harness Skill root must be a directory or a directory symlink."
        case .conflictingRoot:
            "This directory is already registered for another harness."
        case .invalidStoredIdentity:
            "The saved harness Skill root identity is invalid."
        case .persistenceFailed:
            "The harness Skill root could not be saved."
        }
    }
}

/// The user-confirmed root used by a harness. Both the registered spelling and
/// the resolved identity are retained so a replaced volume cannot silently
/// become a new write target.
nonisolated struct HarnessSkillRootConfiguration: Codable, Hashable, Sendable {
    let platform: SkillPlatform
    let registeredURL: URL
    let canonicalURL: URL
    let registeredIdentity: Data
    let canonicalIdentity: Data
    let confirmedAt: Date
}

nonisolated struct HarnessSkillRootResolution: Hashable, Sendable {
    let platform: SkillPlatform
    let status: HarnessSkillRootResolutionStatus
    let registeredURL: URL
    let canonicalURL: URL?
    let configuration: HarnessSkillRootConfiguration?
    let diagnostic: String?

    var isConfigured: Bool { configuration != nil }
    var isUsable: Bool {
        status == .default || status == .configured || status == .environmentHint
    }
}

/// Small UserDefaults-backed configuration store. Environment values are only
/// inspected by `resolution`; they are never persisted or used as write roots.
nonisolated final class HarnessSkillRootConfigurationStore: @unchecked Sendable {
    static let shared = HarnessSkillRootConfigurationStore()

    private static let defaultsKey = "skillsManager.harnessSkillRoots.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configurations() -> [HarnessSkillRootConfiguration] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let values = try? JSONDecoder().decode(
                  [HarnessSkillRootConfiguration].self,
                  from: data
              ) else {
            return []
        }
        return values.sorted { $0.platform.storageKey < $1.platform.storageKey }
    }

    func configuration(for platform: SkillPlatform) -> HarnessSkillRootConfiguration? {
        configurations().first { $0.platform == platform }
    }

    func resolution(
        for platform: SkillPlatform,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HarnessSkillRootResolution {
        if let stored = configuration(for: platform) {
            return inspect(stored, conflict: hasConflict(stored))
        }

        if let hint = environmentHint(for: platform, environment: environment) {
            do {
                let captured = try capture(hint)
                return HarnessSkillRootResolution(
                    platform: platform,
                    status: .environmentHint,
                    registeredURL: captured.registeredURL,
                    canonicalURL: captured.canonicalURL,
                    configuration: nil,
                    diagnostic: "Detected from \(platform.rootEnvironmentVariable ?? "environment") and awaiting confirmation."
                )
            } catch let error as HarnessSkillRootConfigurationError {
                return HarnessSkillRootResolution(
                    platform: platform,
                    status: error == .permissionDenied
                        ? .permissionDenied
                        : .environmentUnavailable,
                    registeredURL: hint,
                    canonicalURL: nil,
                    configuration: nil,
                    diagnostic: error.localizedDescription
                )
            } catch {
                return HarnessSkillRootResolution(
                    platform: platform,
                    status: .environmentUnavailable,
                    registeredURL: hint,
                    canonicalURL: nil,
                    configuration: nil,
                    diagnostic: error.localizedDescription
                )
            }
        }

        let root = defaultRoot(for: platform, homeURL: homeURL)
        return HarnessSkillRootResolution(
            platform: platform,
            status: .default,
            registeredURL: root,
            canonicalURL: root,
            configuration: nil,
            diagnostic: nil
        )
    }

    @discardableResult
    func confirm(
        platform: SkillPlatform,
        registeredURL: URL,
        now: Date = Date()
    ) throws -> HarnessSkillRootConfiguration {
        let captured: CapturedRoot
        do {
            captured = try capture(Self.normalizedURL(registeredURL))
        } catch let error as HarnessSkillRootConfigurationError {
            throw error
        } catch {
            throw HarnessSkillRootConfigurationError.unavailable
        }

        let existing = configurations().filter { $0.platform != platform }
        guard !existing.contains(where: {
            $0.canonicalURL.standardizedFileURL == captured.canonicalURL.standardizedFileURL
        }) else {
            throw HarnessSkillRootConfigurationError.conflictingRoot
        }
        let configuration = HarnessSkillRootConfiguration(
            platform: platform,
            registeredURL: captured.registeredURL,
            canonicalURL: captured.canonicalURL,
            registeredIdentity: try ManagedItemIdentityCodec.encode(captured.registeredIdentity),
            canonicalIdentity: try ManagedItemIdentityCodec.encode(captured.canonicalIdentity),
            confirmedAt: now
        )
        var values = existing
        values.append(configuration)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(values), forKey: Self.defaultsKey)
        } catch {
            throw HarnessSkillRootConfigurationError.persistenceFailed
        }
        return configuration
    }

    func remove(platform: SkillPlatform) {
        let values = configurations().filter { $0.platform != platform }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private struct CapturedRoot {
        let registeredURL: URL
        let canonicalURL: URL
        let registeredIdentity: ManagedItemIdentity
        let canonicalIdentity: ManagedItemIdentity
    }

    private func inspect(
        _ configuration: HarnessSkillRootConfiguration,
        conflict: Bool
    ) -> HarnessSkillRootResolution {
        let registered = configuration.registeredURL.standardizedFileURL
        let fallback = configuration.canonicalURL.standardizedFileURL
        guard !conflict else {
            return HarnessSkillRootResolution(
                platform: configuration.platform,
                status: .conflict,
                registeredURL: registered,
                canonicalURL: fallback,
                configuration: configuration,
                diagnostic: "The saved root conflicts with another harness root."
            )
        }
        do {
            guard let registeredIdentity = try? ManagedItemIdentityCodec.decode(
                configuration.registeredIdentity
            ), let canonicalIdentity = try? ManagedItemIdentityCodec.decode(
                configuration.canonicalIdentity
            ) else {
                throw HarnessSkillRootConfigurationError.invalidStoredIdentity
            }
            let captured = try capture(registered)
            guard captured.registeredIdentity == registeredIdentity,
                  captured.canonicalURL == fallback,
                  captured.canonicalIdentity == canonicalIdentity else {
                return HarnessSkillRootResolution(
                    platform: configuration.platform,
                    status: .changed,
                    registeredURL: registered,
                    canonicalURL: captured.canonicalURL,
                    configuration: configuration,
                    diagnostic: "The saved root or its resolved target changed."
                )
            }
            return HarnessSkillRootResolution(
                platform: configuration.platform,
                status: .configured,
                registeredURL: registered,
                canonicalURL: captured.canonicalURL,
                configuration: configuration,
                diagnostic: nil
            )
        } catch let error as HarnessSkillRootConfigurationError {
            let status: HarnessSkillRootResolutionStatus = switch error {
            case .permissionDenied: .permissionDenied
            case .unsupportedType: .unsupported
            case .invalidStoredIdentity: .changed
            default: .unavailable
            }
            return HarnessSkillRootResolution(
                platform: configuration.platform,
                status: status,
                registeredURL: registered,
                canonicalURL: fallback,
                configuration: configuration,
                diagnostic: error.localizedDescription
            )
        } catch {
            return HarnessSkillRootResolution(
                platform: configuration.platform,
                status: .unavailable,
                registeredURL: registered,
                canonicalURL: fallback,
                configuration: configuration,
                diagnostic: error.localizedDescription
            )
        }
    }

    private func hasConflict(_ configuration: HarnessSkillRootConfiguration) -> Bool {
        configurations().contains { other in
            other.platform != configuration.platform
                && other.canonicalURL.standardizedFileURL
                    == configuration.canonicalURL.standardizedFileURL
        }
    }

    private func environmentHint(
        for platform: SkillPlatform,
        environment: [String: String]
    ) -> URL? {
        guard let variable = platform.rootEnvironmentVariable,
              let value = environment[variable],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let base = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        if base.lastPathComponent == "skills" {
            return base
        }
        return base.appendingPathComponent("skills", isDirectory: true).standardizedFileURL
    }

    private func defaultRoot(for platform: SkillPlatform, homeURL: URL) -> URL {
        homeURL.appendingPathComponent(
            platform.dedicatedDistributionRelativePath,
            isDirectory: true
        ).standardizedFileURL
    }

    private static func normalizedURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw HarnessSkillRootConfigurationError.invalidURL }
        let expanded = (url.path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded != "/" else {
            throw HarnessSkillRootConfigurationError.invalidURL
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    private func capture(_ url: URL) throws -> CapturedRoot {
        let registered = url.standardizedFileURL
        var registeredMetadata = stat()
        guard Darwin.lstat(registered.path, &registeredMetadata) == 0 else {
            throw captureFailure(errno)
        }
        let type = registeredMetadata.st_mode & mode_t(S_IFMT)
        guard type == mode_t(S_IFDIR) || type == mode_t(S_IFLNK) else {
            throw HarnessSkillRootConfigurationError.unsupportedType
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(registered.path, &buffer) != nil else {
            throw captureFailure(errno)
        }
        let canonicalPath = buffer.withUnsafeBufferPointer { pointer in
            let bytes = pointer.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let canonical = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .standardizedFileURL
        var canonicalMetadata = stat()
        guard Darwin.lstat(canonical.path, &canonicalMetadata) == 0 else {
            throw captureFailure(errno)
        }
        guard canonicalMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw HarnessSkillRootConfigurationError.unsupportedType
        }
        return CapturedRoot(
            registeredURL: registered,
            canonicalURL: canonical,
            registeredIdentity: ManagedItemIdentity(registeredMetadata),
            canonicalIdentity: ManagedItemIdentity(canonicalMetadata)
        )
    }

    private func captureFailure(_ code: Int32) -> HarnessSkillRootConfigurationError {
        let error: HarnessSkillRootConfigurationError = code == EACCES || code == EPERM
            ? .permissionDenied
            : .unavailable
        return error
    }
}
