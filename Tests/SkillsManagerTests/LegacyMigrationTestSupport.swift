import Darwin
import Foundation

@testable import SkillsManager

final class LegacyMigrationTestFixture {
    let root: URL
    let home: URL
    let legacyRoot: URL
    let skillState: URL
    let database: URL
    let ownership: SSOTWriterOwnership

    var legacyDirectoryChain: [URL] {
        [
            home,
            home.appendingPathComponent("Library", isDirectory: true),
            home.appendingPathComponent("Library/Application Support", isDirectory: true),
            legacyRoot,
            skillState,
        ]
    }

    init(customPaths: String? = nil, publishStates: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillsmanager-legacy-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        legacyRoot = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SkillsManager", isDirectory: true)
        let managementRoot = root.appendingPathComponent("management", isDirectory: true)
        database = managementRoot.appendingPathComponent("manager.sqlite")

        try createOwnerOnlyDirectory(root)
        try createOwnerOnlyDirectory(home)
        try createOwnerOnlyDirectory(managementRoot)
        try createOwnerOnlyDirectory(legacyRoot)
        skillState = legacyRoot.appendingPathComponent("skill-state", isDirectory: true)
        try createOwnerOnlyDirectory(skillState)
        if let customPaths {
            try writeLegacy(customPaths, to: legacyRoot.appendingPathComponent("custom-paths.json"))
        }
        for (name, json) in publishStates {
            try writeLegacy(json, to: skillState.appendingPathComponent("\(name).json"))
        }
        ownership = try SSOTWriterOwnership.acquire(using: ManagedPathGuard(rootURL: managementRoot))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func connection() throws -> SQLiteConnection {
        try SkillSchemaMigrator.open(at: database)
    }

    func inventory() throws -> LegacyStateInventory {
        try LegacyStateInventory.capture(homeURL: home, ownership: ownership)
    }

    func publishURL(_ name: String) -> URL {
        legacyRoot.appendingPathComponent("skill-state/\(name).json")
    }

    func writePublish(_ name: String, json: String) throws {
        try writeLegacy(json, to: publishURL(name))
    }

    func rewritePublishInPlace(_ name: String, json: String) throws {
        let handle = try FileHandle(forWritingTo: publishURL(name))
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(json.utf8))
        try handle.truncate(atOffset: UInt64(json.utf8.count))
        try handle.synchronize()
    }
}

let legacyCustomPathsFixture = """
[
  {
    "id":"aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb",
    "url":"file:///tmp/example",
    "displayName":"Example",
    "addedAt":-978307200
  }
]
"""

let legacyPublishFixture = """
{"lastPublishedHash":"abc123","lastPublishedAt":-978307199,"hashAlgorithmVersion":1}
"""

func createOwnerOnlyDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard Darwin.chmod(url.path, 0o700) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
    }
}

func writeLegacy(_ string: String, to url: URL) throws {
    try Data(string.utf8).write(to: url, options: .atomic)
    guard Darwin.chmod(url.path, 0o600) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
    }
}
