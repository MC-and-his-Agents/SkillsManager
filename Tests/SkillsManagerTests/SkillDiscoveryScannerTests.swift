import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("Skill discovery scanner")
struct SkillDiscoveryScannerTests {
    @Test("root aliases are scanned once and retain both scopes")
    func rootAliasesAreDeduplicated() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let alias = workspace.appendingPathComponent("skills-alias", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            _ = try createSkill(named: "demo", in: root)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            let roots = [
                SkillDiscoveryRoot(scope: .global, url: root),
                SkillDiscoveryRoot(
                    scope: .agent(adapterCode: "codex", pathVariant: ".codex/skills"),
                    url: alias
                ),
            ]

            let result = try SkillDiscoveryScanner().scan(roots: roots)

            let observation = try #require(result.observations.first)
            #expect(result.observations.count == 1)
            #expect(observation.scopes.count == 2)
            #expect(observation.status == .unmanaged)
            #expect(result.rootDiagnostics.isEmpty)
        }
    }

    @Test("unknown child links are conflicts and are never followed")
    func unknownSymlinkIsNotFollowed() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let outside = workspace.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try "# Outside".write(
                to: outside.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked"),
                withDestinationURL: outside
            )

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            let observation = try #require(result.observations.first)
            #expect(observation.status == .conflict)
            #expect(observation.reason == .unknownSymlink)
            #expect(observation.fingerprint == nil)
        }
    }

    @Test("bad candidates do not hide valid candidates")
    func candidateFailuresAreIsolated() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            _ = try createSkill(named: "valid", in: root)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("missing-manifest"),
                withIntermediateDirectories: false
            )
            let oversized = root.appendingPathComponent("oversized", isDirectory: true)
            try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: false)
            try String(repeating: "x", count: 32).write(
                to: oversized.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            let limits = SkillContentLimits(
                maximumFileCount: 100,
                maximumTotalByteCount: 16,
                maximumFileByteCount: 16
            )

            let result = try SkillDiscoveryScanner().scan(
                roots: [SkillDiscoveryRoot(scope: .global, url: root)],
                limits: limits
            )

            #expect(result.observations.count == 3)
            #expect(result.observations.contains {
                $0.relativeLocator == "missing-manifest"
                    && $0.reason == .missingSkillManifest
            })
            #expect(result.observations.contains {
                $0.relativeLocator == "oversized"
                    && $0.reason == .resourceLimitExceeded
            })
            #expect(result.observations.contains {
                $0.relativeLocator == "valid"
                    && $0.status == .unmanaged
            })
        }
    }

    @Test("bounded Clawdhub metadata only contributes a mapped alias")
    func clawdhubAliasIsBoundedAndMapped() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let skillURL = try createSkill(named: "demo", in: root)
            let metadata = skillURL.appendingPathComponent(".clawdhub", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            try #"{"source":"clawdhub","slug":"demo","version":"1.0.0"}"#.write(
                to: metadata.appendingPathComponent("origin.json"),
                atomically: true,
                encoding: .utf8
            )
            let snapshot = try SkillContentSnapshot.capture(at: skillURL)
            let alias = try ProviderAliasIdentity(provider: "clawdhub", identifier: "demo")
            let managed = SkillDiscoveryManagedSkill(
                skillID: SkillID(),
                fingerprint: try SkillContentFingerprint(
                    currentDigest: snapshot.fingerprintDigest
                ),
                sourceKey: SkillDiscoverySourceKey(
                    repositoryURL: "https://github.com/example/demo",
                    subpath: ""
                ),
                providerAliases: [alias]
            )

            let result = try SkillDiscoveryScanner().scan(
                roots: [SkillDiscoveryRoot(scope: .global, url: root)],
                catalog: SkillDiscoveryCatalog(managedSkills: [managed])
            )

            let observation = try #require(result.observations.first)
            #expect(observation.providerAliases == [alias])
            #expect(observation.status == .claimable)
            #expect(observation.matchedSkillID == managed.skillID)
            #expect(observation.matchedSourceKey == managed.sourceKey)
        }
    }

    @Test("oversized Provider metadata is ignored without failing the Skill")
    func oversizedProviderMetadataIsIgnored() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let skillURL = try createSkill(named: "demo", in: root)
            let metadata = skillURL.appendingPathComponent(".clawdhub", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            try Data(repeating: 0x61, count: 70 * 1_024).write(
                to: metadata.appendingPathComponent("origin.json")
            )

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            let observation = try #require(result.observations.first)
            #expect(observation.status == .unmanaged)
            #expect(observation.providerAliases.isEmpty)
        }
    }

    @Test("missing Provider metadata cannot hide candidate revision drift")
    func missingProviderMetadataStillValidatesCandidateRevision() throws {
        try withWorkspace { workspace in
            let skillURL = try createSkill(named: "demo", in: workspace)
            let descriptor = Darwin.open(
                skillURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            #expect(descriptor >= 0)
            defer { Darwin.close(descriptor) }
            let revision = try #require(SkillDiscoveryFileRevision(descriptor: descriptor))
            try Data().write(to: skillURL.appendingPathComponent("changed"))

            #expect(throws: SkillContentSnapshotError.fileChanged(
                path: ".clawdhub/origin.json"
            )) {
                _ = try SkillDiscoveryProviderMetadataReader().aliases(
                    in: descriptor,
                    expectedCandidate: revision,
                    checkpoint: {}
                )
            }
        }
    }

    @Test("invalid UTF-8 manifests are damaged")
    func invalidManifestIsDamaged() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let skill = root.appendingPathComponent("demo", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data([0xFF, 0xFE]).write(to: skill.appendingPathComponent("SKILL.md"))

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            let observation = try #require(result.observations.first)
            #expect(observation.status == .damaged)
            #expect(observation.reason == .invalidSkillManifest)
            #expect(observation.fingerprint == nil)
        }
    }

    @Test("decomposed directory names are opened by their raw name and reported as NFC")
    func decomposedDirectoryNameIsNormalized() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            _ = try createSkill(named: "cafe\u{301}", in: root)

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            let observation = try #require(result.observations.first)
            #expect(observation.relativeLocator == "café")
            #expect(observation.relativeLocatorKey == "café")
            #expect(observation.status == .unmanaged)
        }
    }

    @Test("unreadable roots produce permission diagnostics")
    func unreadableRootIsReported() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            _ = try createSkill(named: "demo", in: root)
            #expect(Darwin.chmod(root.path, 0) == 0)
            defer { _ = Darwin.chmod(root.path, S_IRWXU) }

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: root),
            ])

            #expect(result.observations.isEmpty)
            #expect(result.rootDiagnostics == [
                SkillDiscoveryRootDiagnostic(
                    root: SkillDiscoveryRoot(scope: .global, url: root),
                    reason: .rootPermissionDenied
                ),
            ])
        }
    }

    @Test("root replacement during scanning fails closed")
    func rootReplacementIsReported() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let displaced = workspace.appendingPathComponent("skills-old", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            _ = try createSkill(named: "demo", in: root)
            var checkpoints = 0

            let result = try SkillDiscoveryScanner().scan(
                roots: [SkillDiscoveryRoot(scope: .global, url: root)],
                checkpoint: {
                    checkpoints += 1
                    if checkpoints == 3 {
                        try FileManager.default.moveItem(at: root, to: displaced)
                        try FileManager.default.createDirectory(
                            at: root,
                            withIntermediateDirectories: false
                        )
                    }
                }
            )

            #expect(result.observations.isEmpty)
            #expect(result.rootDiagnostics.contains { $0.reason == .rootChanged })
        }
    }

    @Test("one changed root alias does not discard a still-verified alias")
    func changedAliasKeepsVerifiedScope() throws {
        try withWorkspace { workspace in
            let root = workspace.appendingPathComponent("skills", isDirectory: true)
            let alias = workspace.appendingPathComponent("alias", isDirectory: true)
            let other = workspace.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            _ = try createSkill(named: "demo", in: root)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            let aliasScope = SkillDiscoveryScope.agent(
                adapterCode: "codex",
                pathVariant: ".codex/skills"
            )
            var checkpoints = 0

            let result = try SkillDiscoveryScanner().scan(
                roots: [
                    SkillDiscoveryRoot(scope: .global, url: root),
                    SkillDiscoveryRoot(scope: aliasScope, url: alias),
                ],
                checkpoint: {
                    checkpoints += 1
                    if checkpoints == 3 {
                        try FileManager.default.removeItem(at: alias)
                        try FileManager.default.createSymbolicLink(
                            at: alias,
                            withDestinationURL: other
                        )
                    }
                }
            )

            let observation = try #require(result.observations.first)
            #expect(observation.scopes == [.global])
            #expect(result.rootDiagnostics == [
                SkillDiscoveryRootDiagnostic(
                    root: SkillDiscoveryRoot(scope: aliasScope, url: alias),
                    reason: .rootChanged
                ),
            ])
        }
    }

    @Test("missing roots are empty while unsupported roots remain visible")
    func rootFailuresAreIsolated() throws {
        try withWorkspace { workspace in
            let valid = workspace.appendingPathComponent("valid", isDirectory: true)
            let missing = workspace.appendingPathComponent("missing", isDirectory: true)
            let unsupported = workspace.appendingPathComponent("file")
            try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: false)
            _ = try createSkill(named: "demo", in: valid)
            try Data("not a root".utf8).write(to: unsupported)

            let result = try SkillDiscoveryScanner().scan(roots: [
                SkillDiscoveryRoot(scope: .global, url: valid),
                SkillDiscoveryRoot(
                    scope: .agent(adapterCode: "codex", pathVariant: ".codex/skills"),
                    url: missing
                ),
                SkillDiscoveryRoot(
                    scope: .agent(adapterCode: "claude", pathVariant: ".claude/skills"),
                    url: unsupported
                ),
            ])

            #expect(result.observations.count == 1)
            #expect(result.rootDiagnostics.count == 1)
            #expect(result.rootDiagnostics[0].reason == .rootUnsupportedType)
        }
    }

    private func createSkill(named name: String, in root: URL) throws -> URL {
        let skill = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: false)
        try "# \(name)".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return skill
    }

    private func withWorkspace(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
