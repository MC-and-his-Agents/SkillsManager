import Darwin
import Foundation

nonisolated enum LibraryStartupCheckpoint: String, Sendable {
    case markerDurable
    case databasePrepared
    case migrationCommitted
    case ssotDurable
    case databaseCompleted
    case markerRemoved
}

nonisolated struct LibraryStartupHooks: Sendable {
    let checkpoint: @Sendable (LibraryStartupCheckpoint) throws -> Void

    init(checkpoint: @escaping @Sendable (LibraryStartupCheckpoint) throws -> Void = { _ in }) {
        self.checkpoint = checkpoint
    }
}

nonisolated final class LibraryStartupCoordinator: Sendable {
    private let homeURL: URL
    private let hooks: LibraryStartupHooks

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        hooks: LibraryStartupHooks = .init()
    ) {
        self.homeURL = homeURL
        self.hooks = hooks
    }

    func start() async -> LibraryStartupResult {
        var phase = LibraryRuntimePhase.classifying
        do {
            let layout = LibraryRootLayout(homeURL: homeURL)
            let hasLegacyHistory = try LegacyStateInventory.hasHistory(homeURL: homeURL)
            phase = .creatingManagementRoot
            let admission = try LibraryRootBootstrap.openOrCreateManagementRoot(layout: layout)
            let managementRoot = admission.root

            phase = .acquiringOwnership
            let ownership = try SSOTWriterOwnership.acquire(
                using: ManagedPathGuard(verifiedRoot: managementRoot)
            )
            try managementRoot.revalidate()
            let names = Set(try LibraryRootBootstrap.managementEntryNames(managementRoot))
            let markerExists = names.contains(LibraryRootLayout.bootstrapMarkerName)
            let databaseExists = names.contains(LibraryRootLayout.databaseFileName)
            let ssotExists = names.contains(LibraryRootLayout.ssotDirectoryName)

            if !databaseExists && !ssotExists {
                phase = .bootstrapping
                let marker = try prepareMarker(
                    markerExists: markerExists,
                    hasLegacyHistory: hasLegacyHistory,
                    managementRoot: managementRoot
                )
                return try await finishBootstrap(
                    layout: layout,
                    managementRoot: managementRoot,
                    ownership: ownership,
                    marker: marker
                )
            }

            if !databaseExists {
                return blocked(
                    phase: phase,
                    .make(.databaseMissing, subjectKind: .database, subjectID: "manager.sqlite")
                )
            }

            phase = .openingDatabase
            let marker = try markerExists
                ? LibraryRootBootstrap.openMarker(root: managementRoot)
                : nil
            if marker != nil {
                try LibraryRootBootstrap.requireOnlyManagementEntries(
                    [
                        SSOTWriterOwnership.lockFileName,
                        LibraryRootLayout.bootstrapMarkerName,
                        LibraryRootLayout.databaseFileName,
                        "\(LibraryRootLayout.databaseFileName)-shm",
                        "\(LibraryRootLayout.databaseFileName)-wal",
                        LibraryRootLayout.ssotDirectoryName,
                    ],
                    root: managementRoot
                )
            }
            let connection = try SkillSchemaMigrator.open(
                at: layout.databaseURL,
                accessMode: .readWriteExisting,
                initializeV4: { connection in
                    guard let marker else { return }
                    try LibraryBootstrapStore.insertPrepared(
                        kind: marker.marker.bootstrapKind,
                        bootstrapID: marker.marker.bootstrapID,
                        expectedMarkerIdentity: marker.identity,
                        connection: connection
                    )
                }
            )
            let bootstrap = try LibraryBootstrapStore.load(connection)
            try validateBootstrapPair(record: bootstrap, marker: marker)

            if !ssotExists {
                guard let bootstrap, bootstrap.state == .prepared, let marker else {
                    return blocked(
                        phase: phase,
                        .make(.ssotMissing, subjectKind: .ssot, subjectID: "skills")
                    )
                }
                phase = .bootstrapping
                return try await finishBootstrap(
                    layout: layout,
                    managementRoot: managementRoot,
                    ownership: ownership,
                    marker: marker,
                    connection: connection,
                    record: bootstrap
                )
            }

            if let bootstrap, bootstrap.state == .prepared {
                guard let marker else {
                    return blocked(
                        phase: phase,
                        .make(.unrecoverable, subjectKind: .bootstrap, subjectID: "markerMissing")
                    )
                }
                phase = .bootstrapping
                return try await finishBootstrap(
                    layout: layout,
                    managementRoot: managementRoot,
                    ownership: ownership,
                    marker: marker,
                    connection: connection,
                    record: bootstrap
                )
            }

            var diagnostics: [LibraryRuntimeDiagnostic] = []
            if let bootstrap, bootstrap.state == .completed, let marker {
                do {
                    try LibraryRootBootstrap.removeMarker(
                        expectedIdentity: marker.identity,
                        root: managementRoot
                    )
                } catch {
                    diagnostics.append(.make(
                        .cleanupDebt,
                        subjectKind: .bootstrap,
                        subjectID: bootstrap.bootstrapID.uuidString.lowercased()
                    ))
                }
                if diagnostics.isEmpty {
                    try hooks.checkpoint(.markerRemoved)
                }
            }

            let ssotRoot = try LibraryRootBootstrap.openExistingSSOT(
                layout: layout,
                root: managementRoot
            )
            phase = .recovering
            let writer = try await JournaledSSOTWriter.open(
                managementRoot: managementRoot,
                ssotRoot: ssotRoot,
                connection: connection,
                ownership: ownership
            )
            phase = .migratingLegacy
            let migration = try await writer.migrateLegacy(homeURL: homeURL)
            diagnostics.append(contentsOf: migrationDiagnostics(migration))
            phase = .checking
            diagnostics.append(contentsOf: try await writer.healthDiagnostics())
            return readyResult(diagnostics: diagnostics, writer: writer, outcome: .opened)
        } catch {
            return blocked(phase: phase, diagnostic(for: error))
        }
    }

    private func prepareMarker(
        markerExists: Bool,
        hasLegacyHistory: Bool,
        managementRoot: VerifiedSSOTRoot
    ) throws -> LibraryBootstrapMarkerHandle {
        if markerExists {
            let marker = try LibraryRootBootstrap.openMarker(root: managementRoot)
            guard marker.marker.bootstrapKind == (hasLegacyHistory ? .legacy : .fresh) else {
                throw LibraryRootBootstrapError.invalidMarker
            }
            try LibraryRootBootstrap.requireOnlyManagementEntries(
                [SSOTWriterOwnership.lockFileName, LibraryRootLayout.bootstrapMarkerName],
                root: managementRoot
            )
            return marker
        }
        try LibraryRootBootstrap.requireOnlyManagementEntries(
            [SSOTWriterOwnership.lockFileName],
            root: managementRoot
        )
        let marker = try LibraryRootBootstrap.createMarker(
            LibraryBootstrapMarker(kind: hasLegacyHistory ? .legacy : .fresh),
            root: managementRoot
        )
        try hooks.checkpoint(.markerDurable)
        return marker
    }

    private func finishBootstrap(
        layout: LibraryRootLayout,
        managementRoot: VerifiedSSOTRoot,
        ownership: SSOTWriterOwnership,
        marker: LibraryBootstrapMarkerHandle,
        connection suppliedConnection: SQLiteConnection? = nil,
        record suppliedRecord: LibraryBootstrapRecord? = nil
    ) async throws -> LibraryStartupResult {
        let allowed = Set([
            SSOTWriterOwnership.lockFileName,
            LibraryRootLayout.bootstrapMarkerName,
            LibraryRootLayout.databaseFileName,
            "\(LibraryRootLayout.databaseFileName)-shm",
            "\(LibraryRootLayout.databaseFileName)-wal",
            LibraryRootLayout.ssotDirectoryName,
        ])
        try LibraryRootBootstrap.requireOnlyManagementEntries(allowed, root: managementRoot)
        let historyNow = try LegacyStateInventory.hasHistory(homeURL: homeURL)
        guard marker.marker.bootstrapKind == (historyNow ? .legacy : .fresh) else {
            throw LibraryRootBootstrapError.invalidMarker
        }

        let connection: SQLiteConnection
        if let suppliedConnection {
            connection = suppliedConnection
        } else {
            connection = try SkillSchemaMigrator.open(
                at: layout.databaseURL,
                accessMode: .readWrite,
                initializeV4: { connection in
                    try LibraryBootstrapStore.insertPrepared(
                        kind: marker.marker.bootstrapKind,
                        bootstrapID: marker.marker.bootstrapID,
                        expectedMarkerIdentity: marker.identity,
                        connection: connection
                    )
                }
            )
        }
        let record = try suppliedRecord ?? LibraryBootstrapStore.load(connection)
        guard let record else {
            throw SQLiteStoreError.invalidState("bootstrap metadata is missing")
        }
        try validateBootstrapPair(record: record, marker: marker)
        do {
            let managementDescriptor = try managementRoot.duplicateDescriptor()
            defer { Darwin.close(managementDescriptor) }
            try SSOTDurability.syncDirectory(managementDescriptor)
        }
        try hooks.checkpoint(.databasePrepared)

        if try LegacyMigrationLedgerAdmission.read(connection) == nil {
            _ = try LegacyStateMigrationGate.migrateIfNeeded(
                homeURL: homeURL,
                connection: connection,
                ownership: ownership
            )
        }
        _ = try LegacyMigrationLedgerAdmission.requireCompleted(connection)
        try hooks.checkpoint(.migrationCommitted)

        let ssotRoot = try LibraryRootBootstrap.createOrOpenSSOT(
            layout: layout,
            root: managementRoot
        )
        let descriptor = try ssotRoot.duplicateDescriptor()
        defer { Darwin.close(descriptor) }
        guard try SafeSourceTree.names(in: descriptor, displayPath: "skills").isEmpty else {
            throw LibraryRootBootstrapError.unexpectedManagementEntry("skills")
        }
        try hooks.checkpoint(.ssotDurable)

        var completed = record
        if record.state == .prepared {
            try connection.withImmediateTransaction {
                try LibraryBootstrapStore.complete(expected: record, connection: connection)
            }
            completed = try LibraryBootstrapStore.load(connection)
                ?? record
            try hooks.checkpoint(.databaseCompleted)
        }
        guard completed.state == .completed else {
            throw SQLiteStoreError.invalidState("bootstrap did not complete")
        }

        var diagnostics: [LibraryRuntimeDiagnostic] = []
        do {
            try LibraryRootBootstrap.removeMarker(
                expectedIdentity: marker.identity,
                root: managementRoot
            )
        } catch {
            diagnostics.append(.make(
                .cleanupDebt,
                subjectKind: .bootstrap,
                subjectID: completed.bootstrapID.uuidString.lowercased()
            ))
        }
        if diagnostics.isEmpty {
            try hooks.checkpoint(.markerRemoved)
        }

        let writer = try await JournaledSSOTWriter.open(
            managementRoot: managementRoot,
            ssotRoot: ssotRoot,
            connection: connection,
            ownership: ownership
        )
        diagnostics.append(contentsOf: try await writer.healthDiagnostics())
        return readyResult(
            diagnostics: diagnostics,
            writer: writer,
            outcome: .firstRunInitialized
        )
    }

    private func validateBootstrapPair(
        record: LibraryBootstrapRecord?,
        marker: LibraryBootstrapMarkerHandle?
    ) throws {
        switch (record, marker) {
        case (nil, nil):
            return
        case (let record?, nil) where record.state == .completed:
            return
        case (let record?, let marker?):
            guard record.kind == marker.marker.bootstrapKind,
                  record.bootstrapID == marker.marker.bootstrapID,
                  record.expectedMarkerIdentity == marker.identity else {
                throw LibraryRootBootstrapError.invalidMarker
            }
        default:
            throw LibraryRootBootstrapError.invalidMarker
        }
    }

    private func migrationDiagnostics(
        _ result: LegacyMigrationResult
    ) -> [LibraryRuntimeDiagnostic] {
        result.archiveChanged ? [
            .make(.legacyArchiveChanged, subjectKind: .legacy, subjectID: "archive"),
        ] : []
    }

    private func readyResult(
        diagnostics: [LibraryRuntimeDiagnostic],
        writer: JournaledSSOTWriter,
        outcome: LibraryStartupOutcome
    ) -> LibraryStartupResult {
        let normalized = LibraryRuntimeDiagnostic.normalized(diagnostics)
        guard !normalized.contains(where: \.blocking) else {
            return LibraryStartupResult(
                phase: .checking,
                readiness: .blocked,
                diagnostics: normalized,
                outcome: outcome,
                session: nil
            )
        }
        return LibraryStartupResult(
            phase: .running,
            readiness: .ready,
            diagnostics: normalized,
            outcome: outcome,
            session: writer
        )
    }

    private func blocked(
        phase: LibraryRuntimePhase,
        _ diagnostic: LibraryRuntimeDiagnostic
    ) -> LibraryStartupResult {
        LibraryStartupResult(
            phase: phase,
            readiness: .blocked,
            diagnostics: LibraryRuntimeDiagnostic.normalized([diagnostic]),
            outcome: nil,
            session: nil
        )
    }

    private func diagnostic(for error: Error) -> LibraryRuntimeDiagnostic {
        if let error = error as? SSOTWriterOwnershipError {
            let code: LibraryDiagnosticCode = switch error {
            case .busy: .databaseBusy
            case .invalidLockFile, .posix: .permissionDenied
            }
            return .make(code, subjectKind: .library, subjectID: "ownership")
        }
        if let error = error as? ManagedPathError {
            return .make(
                error == .rootReplaced ? .rootIdentityChanged : .permissionDenied,
                subjectKind: .library,
                subjectID: "managementRoot"
            )
        }
        if let error = error as? LegacyMigrationFailure {
            return .make(
                error.code == .databaseBusy ? .databaseBusy : .legacyMigrationBlocked,
                subjectKind: .legacy,
                subjectID: error.locator ?? "archive"
            )
        }
        if let error = error as? JournaledSSOTWriterError {
            let code: LibraryDiagnosticCode = switch error {
            case .operationNeedsRepair: .journalNeedsRepair
            default: .unrecoverable
            }
            return .make(code, subjectKind: .journal, subjectID: "operation")
        }
        if case SQLiteStoreError.sqlite(_, let code, _) = error {
            let primary = code & 0xff
            return .make(
                primary == 5 || primary == 6 ? .databaseBusy : .schemaMismatch,
                subjectKind: .database,
                subjectID: "manager.sqlite"
            )
        }
        if error is SQLiteStoreError {
            return .make(
                .schemaMismatch,
                subjectKind: .database,
                subjectID: "manager.sqlite"
            )
        }
        if case LibraryRootBootstrapError.posix(_, let code) = error,
           code == EACCES || code == EPERM {
            return .make(
                .permissionDenied,
                subjectKind: .library,
                subjectID: "managementRoot"
            )
        }
        return .make(.unrecoverable, subjectKind: .library, subjectID: "startup")
    }
}
