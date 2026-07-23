import Foundation

nonisolated enum LibraryBootstrapKind: String, Codable, Sendable {
    case fresh
    case legacy
}

nonisolated enum LibraryBootstrapDatabaseState: String, Sendable {
    case prepared
    case completed
}

nonisolated struct LibraryBootstrapRecord: Equatable, Sendable {
    let kind: LibraryBootstrapKind
    let bootstrapID: UUID
    let expectedMarkerIdentity: ManagedItemIdentity
    let state: LibraryBootstrapDatabaseState
}

nonisolated enum LibraryBootstrapStore {
    static func load(_ connection: SQLiteConnection) throws -> LibraryBootstrapRecord? {
        let statement = try connection.prepare(
            """
            SELECT format_version, bootstrap_kind, bootstrap_id,
              expected_marker_identity, state
            FROM library_bootstrap ORDER BY singleton
            """
        )
        guard try statement.step() else { return nil }
        guard statement.int64(at: 0) == 1,
              let kindValue = statement.text(at: 1),
              let kind = LibraryBootstrapKind(rawValue: kindValue),
              let idBytes = statement.blob(at: 2),
              let identityBytes = statement.blob(at: 3),
              let stateValue = statement.text(at: 4),
              let state = LibraryBootstrapDatabaseState(rawValue: stateValue),
              try !statement.step() else {
            throw SQLiteStoreError.invalidState("library bootstrap metadata is invalid")
        }
        return LibraryBootstrapRecord(
            kind: kind,
            bootstrapID: try catalogUUID(from: idBytes),
            expectedMarkerIdentity: try ManagedItemIdentityCodec.decode(identityBytes),
            state: state
        )
    }

    static func insertPrepared(
        kind: LibraryBootstrapKind,
        bootstrapID: UUID,
        expectedMarkerIdentity: ManagedItemIdentity,
        connection: SQLiteConnection
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO library_bootstrap(
              singleton, format_version, bootstrap_kind, bootstrap_id,
              expected_marker_identity, state
            ) VALUES (1, 1, ?, ?, ?, 'prepared')
            """
        )
        try statement.bind(kind.rawValue, at: 1)
        try statement.bind(catalogUUIDBytes(bootstrapID), at: 2)
        try statement.bind(ManagedItemIdentityCodec.encode(expectedMarkerIdentity), at: 3)
        guard try !statement.step() else {
            throw SQLiteStoreError.invalidState("bootstrap insert unexpectedly returned a row")
        }
    }

    static func complete(
        expected: LibraryBootstrapRecord,
        connection: SQLiteConnection
    ) throws {
        guard expected.state == .prepared else {
            throw SQLiteStoreError.invalidState("only prepared bootstrap may be completed")
        }
        let statement = try connection.prepare(
            """
            UPDATE library_bootstrap SET state = 'completed'
            WHERE singleton = 1 AND state = 'prepared' AND bootstrap_kind = ?
              AND bootstrap_id = ? AND expected_marker_identity = ?
            """
        )
        try statement.bind(expected.kind.rawValue, at: 1)
        try statement.bind(catalogUUIDBytes(expected.bootstrapID), at: 2)
        try statement.bind(ManagedItemIdentityCodec.encode(expected.expectedMarkerIdentity), at: 3)
        guard try !statement.step(),
              try connection.querySingleInt("SELECT changes()") == 1 else {
            throw SQLiteStoreError.invalidState("bootstrap completion identity changed")
        }
    }
}
