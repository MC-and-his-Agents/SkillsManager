import Foundation
import Testing

@testable import SkillsManager

@Suite("Managed ClawHub update boundaries")
struct ManagedClawdhubUpdateBoundaryTests {
    @Test("typed filesystem permission errors use stable permission semantics")
    func typedPermissionErrors() {
        let errors: [Error] = [
            SSOTOperationFileSystemError.posix(operation: "stage", code: EACCES),
            SSOTDurabilityError.posix(operation: "sync", code: EPERM),
            SkillBackupFileSystemError.posix(operation: "backup", code: EACCES),
            CopyForkError.permissionDenied,
        ]

        for error in errors {
            #expect(managedInstallKnownProblem(for: error) == .permissionDenied)
        }
    }

    @Test("Copy Fork admission uses stable install operation semantics")
    func copyForkAdmissionErrors() {
        #expect(
            managedInstallKnownProblem(for: CopyForkError.operationInProgress)
                == .operationInProgress
        )
        #expect(
            managedInstallKnownProblem(for: CopyForkError.needsRepair)
                == .needsRepair
        )
    }

    @Test("a damaged update backup blocks preparation with repair semantics")
    func backupRepairBlocksPreparation() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                existingPayload: existing.payload,
                existingProvenance: existing.provenance,
                baselineNeedsRepair: true
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())

            await #expect(throws: ManagedLocalImportProblem.needsRepair) {
                _ = try await service.prepareClawdhub(
                    candidate: candidate,
                    skill: remoteSkill(version: "2.0.0"),
                    scope: .global
                )
            }
            #expect(await probe.replaceCount == 0)
        }
    }

    @Test("pre-journal failure keeps the old Skill and permits a fresh preview")
    func preJournalFailureIsRetrySafe() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                replaceFailure: .beforeJournal,
                operationReadbackFound: false,
                existingPayload: existing.payload,
                existingProvenance: existing.provenance
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let first = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "2.0.0"),
                scope: .global
            )

            await #expect(throws: ManagedLocalImportProblem.self) {
                _ = try await service.execute(first.token)
            }
            let retry = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "2.0.0"),
                scope: .global
            )

            #expect(first.token != retry.token)
            #expect(await probe.replaceCount == 1)
            #expect(await probe.reconcileCount == 0)
        }
    }

    @Test("missing journal with committed replacement is read back as updated")
    func committedDomainWinsMissingJournal() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                replaceFailure: .afterCommit,
                operationReadbackFound: false,
                existingPayload: existing.payload,
                existingProvenance: existing.provenance
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "2.0.0"),
                scope: .global
            )

            let result = try await service.execute(preview.token)

            #expect(result.status == .updated)
            #expect(await probe.replaceCount == 1)
            #expect(await probe.reconcileCount == 1)
        }
    }

    @Test("repair readback blocks a repeated write")
    func repairReadbackFailsClosed() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                readbackState: .init(
                    phase: .completed,
                    outcome: .needsRepair,
                    cleanupState: .needsRepair
                ),
                existingPayload: existing.payload,
                existingProvenance: existing.provenance
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "2.0.0"),
                scope: .global
            )

            await #expect(throws: ManagedLocalImportProblem.needsRepair) {
                _ = try await service.execute(preview.token)
            }
            await #expect(throws: ManagedLocalImportProblem.needsRepair) {
                _ = try await service.execute(preview.token)
            }
            #expect(await probe.replaceCount == 1)
            #expect(await probe.reconcileCount == 0)
        }
    }

    @Test(
        "reconcile uncertainty preserves the completed update",
        arguments: [false, true]
    )
    func reconcileUncertainty(needsRepair: Bool) async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                existingPayload: existing.payload,
                existingProvenance: existing.provenance,
                reconcileStatus: needsRepair ? .needsRepair : .inSync,
                reconcileThrows: !needsRepair
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "2.0.0"),
                scope: .global
            )

            let result = try await service.execute(preview.token)

            #expect(result.status == .updatedDistributionNeedsAttention)
            #expect(await probe.replaceCount == 1)
            #expect(await probe.reconcileCount == 1)
        }
    }

    @Test("concurrent confirmation runs one update")
    func concurrentConfirmationIsSingleFlight() async throws {
        try await withImportCandidate { candidate in
            let existing = try existingDomain(candidate: candidate, version: "1.0.0")
            let probe = ManagedLocalImportProbe(
                replaceDelay: .milliseconds(50),
                existingPayload: existing.payload,
                existingProvenance: existing.provenance
            )
            let service = ManagedInstallService(dependencies: probe.dependencies())
            let preview = try await service.prepareClawdhub(
                candidate: candidate,
                skill: remoteSkill(version: "2.0.0"),
                scope: .global
            )
            let first = Task { try await service.execute(preview.token) }
            #expect(await probe.waitUntilReplaceStarts())

            await #expect(throws: ManagedLocalImportProblem.operationInProgress) {
                _ = try await service.execute(preview.token)
            }
            #expect(try await first.value.status == .updated)
            #expect(await probe.replaceCount == 1)
        }
    }
}
