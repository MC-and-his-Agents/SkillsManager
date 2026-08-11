import Darwin
import Foundation
import Testing

@testable import SkillsManager

@Suite("LibraryHealth")
struct LibraryHealthTests {
    @Test("reports drift, missing records, orphan UUID directories, and unknown entries together")
    func aggregatesHealthDiagnostics() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        let result = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        let writer = try #require(result.session)
        let source = try fixture.makeSourceSkill()
        let drifted = try makeManagedSkill(snapshot: source.1)
        _ = try await writer.create(
            payload: SSOTSkillWritePayload(skill: drifted),
            sourceSnapshot: source.1
        )
        let missing = try makeManagedSkill(snapshot: source.1)
        _ = try await writer.create(
            payload: SSOTSkillWritePayload(skill: missing),
            sourceSnapshot: source.1
        )
        let ssot = fixture.home.appendingPathComponent(".SkillsManager/skills", isDirectory: true)
        try Data("# Changed\n".utf8).write(
            to: ssot.appendingPathComponent(drifted.skillID.directoryName)
                .appendingPathComponent("SKILL.md")
        )
        try FileManager.default.removeItem(
            at: ssot.appendingPathComponent(missing.skillID.directoryName, isDirectory: true)
        )
        let orphanName = UUID().uuidString.lowercased()
        let orphan = ssot.appendingPathComponent(orphanName, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        #expect(Darwin.chmod(orphan.path, 0o700) == 0)
        try Data("unknown".utf8).write(to: ssot.appendingPathComponent(".unknown"))

        let diagnostics = try await writer.healthDiagnostics()
        #expect(diagnostics.contains {
            $0.code == .contentFingerprintDrift && $0.subjectID == drifted.skillID.directoryName
        })
        #expect(diagnostics.contains {
            $0.code == .databaseSkillMissingDirectory
                && $0.subjectID == missing.skillID.directoryName
        })
        #expect(diagnostics.contains {
            $0.code == .orphanSSOTDirectory && $0.subjectID == orphanName
        })
        #expect(diagnostics.contains {
            $0.code == .unknownSSOTEntry && $0.subjectID == ".unknown"
        })
        #expect(diagnostics == LibraryRuntimeDiagnostic.normalized(diagnostics))
    }

    @Test("regular Finder metadata is ignored but a non-regular entry is blocking")
    func finderMetadataPolicy() async throws {
        let fixture = try LibraryRuntimeTestHome()
        defer { fixture.remove() }
        var initial = await LibraryStartupCoordinator(homeURL: fixture.home).start()
        let writer = try #require(initial.session)
        initial = LibraryStartupResult(
            phase: initial.phase,
            readiness: initial.readiness,
            diagnostics: initial.diagnostics,
            outcome: initial.outcome,
            session: nil
        )
        let ssot = fixture.home.appendingPathComponent(".SkillsManager/skills", isDirectory: true)
        try Data().write(to: ssot.appendingPathComponent(".DS_Store"))

        let ignored = try await writer.healthDiagnostics()
        #expect(!ignored.contains { $0.subjectID == ".DS_Store" })

        try FileManager.default.removeItem(at: ssot.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(
            at: ssot.appendingPathComponent(".DS_Store"),
            withIntermediateDirectories: false
        )
        let blocked = try await writer.healthDiagnostics()
        #expect(blocked.contains {
            $0.code == .unknownSSOTEntry && $0.subjectID == ".DS_Store" && $0.blocking
        })
    }

    @Test("diagnostic policy keeps only cleanup and legacy warnings non-blocking")
    func fixedDiagnosticPolicy() {
        for code in [
            LibraryDiagnosticCode.cleanupDebt,
            .legacyArchiveChanged,
        ] {
            #expect(!LibraryRuntimeDiagnostic.make(
                code,
                subjectKind: .library,
                subjectID: "x"
            ).blocking)
        }
        for code in LibraryDiagnosticCode.allBlockingCases {
            #expect(LibraryRuntimeDiagnostic.make(
                code,
                subjectKind: .library,
                subjectID: "x"
            ).blocking)
        }
    }
}

private extension LibraryDiagnosticCode {
    static let allBlockingCases: [Self] = [
        .databaseMissing,
        .ssotMissing,
        .schemaMismatch,
        .legacyMigrationBlocked,
        .journalNeedsRepair,
        .orphanSSOTDirectory,
        .unknownSSOTEntry,
        .databaseSkillMissingDirectory,
        .contentFingerprintDrift,
        .rootIdentityChanged,
        .permissionDenied,
        .databaseBusy,
        .unrecoverable,
    ]
}
