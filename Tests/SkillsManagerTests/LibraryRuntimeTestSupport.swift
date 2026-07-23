import Darwin
import Foundation

@testable import SkillsManager

struct LibraryRuntimeTestHome {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "skillsmanager-library-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        guard Darwin.chmod(root.path, 0o700) == 0,
              Darwin.chmod(home.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeLegacyCustomPaths(_ paths: [CustomSkillPath]) throws -> (URL, Data, stat) {
        let legacy = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SkillsManager", isDirectory: true)
        try createOwnerOnlyDirectoryChain(legacy)
        let url = legacy.appendingPathComponent("custom-paths.json")
        let bytes = try JSONEncoder().encode(paths)
        try bytes.write(to: url)
        guard Darwin.chmod(url.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return (url, bytes, metadata)
    }

    func makeSourceSkill() throws -> (URL, SkillContentSnapshot) {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        guard Darwin.chmod(source.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try Data("# Demo\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        return (source, try SkillContentSnapshot.capture(at: source))
    }
}

func makeManagedSkill(
    snapshot: SkillContentSnapshot,
    id: SkillID = SkillID()
) throws -> ManagedSkillRecord {
    try ManagedSkillRecord(
        skillID: id,
        displayName: SkillDisplayName("Demo"),
        defaultDistributionSlug: DefaultDistributionSlug(validating: "demo"),
        contentFingerprint: SkillContentFingerprint(currentDigest: snapshot.fingerprintDigest),
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
}

private func createOwnerOnlyDirectoryChain(_ leaf: URL) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in leaf.pathComponents.dropFirst() {
        current.appendPathComponent(component, isDirectory: true)
        if !FileManager.default.fileExists(atPath: current.path) {
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        }
        if current.path.hasPrefix(leaf.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path) {
            guard Darwin.chmod(current.path, 0o700) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
    }
}
