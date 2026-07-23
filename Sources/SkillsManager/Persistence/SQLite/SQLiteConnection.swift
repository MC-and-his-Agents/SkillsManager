import Foundation
import SQLite3

nonisolated enum SQLiteStoreError: Error, Equatable, LocalizedError {
    case sqlite(operation: String, code: Int32, message: String)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let operation, let code, let message):
            "SQLite \(operation) failed (\(code)): \(message)"
        case .invalidState(let message):
            "Invalid SQLite state: \(message)"
        }
    }
}

nonisolated enum SQLiteAccessMode: Equatable, Sendable {
    case readWrite
    case readOnly
}

/// A deliberately non-Sendable SQLite connection. The composition root owns serialization.
nonisolated final class SQLiteConnection {
    private let database: OpaquePointer
    let accessMode: SQLiteAccessMode

    init(path: String, accessMode: SQLiteAccessMode = .readWrite) throws {
        var opened: OpaquePointer?
        let flags: Int32 = switch accessMode {
        case .readWrite:
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(result))
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteStoreError.sqlite(operation: "open", code: result, message: message)
        }
        database = opened
        self.accessMode = accessMode
        sqlite3_extended_result_codes(database, 1)

        do {
            try execute("PRAGMA foreign_keys = ON")
            try requireIntegerPragma("foreign_keys", equals: 1)

            guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else {
                throw currentError(operation: "set busy timeout")
            }
            try requireIntegerPragma("busy_timeout", equals: 5_000)

            try execute("PRAGMA synchronous = FULL")
            try requireIntegerPragma("synchronous", equals: 2)

            switch accessMode {
            case .readWrite:
                try requireIntegerPragma("query_only", equals: 0)
            case .readOnly:
                try execute("PRAGMA query_only = ON")
                try requireIntegerPragma("query_only", equals: 1)
            }
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
    }

    convenience init(url: URL, accessMode: SQLiteAccessMode = .readWrite) throws {
        try self.init(path: url.path, accessMode: accessMode)
    }

    deinit {
        sqlite3_close_v2(database)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw SQLiteStoreError.sqlite(operation: "execute", code: result, message: detail)
        }
    }

    func withImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw currentError(operation: "prepare")
        }
        return SQLiteStatement(statement: statement)
    }

    func querySingleInt(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        let value = statement.int64(at: 0)
        guard try !statement.step() else {
            throw SQLiteStoreError.invalidState("query returned more than one row")
        }
        return value
    }

    func querySingleText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        let value = statement.text(at: 0)
        guard try !statement.step() else {
            throw SQLiteStoreError.invalidState("query returned more than one row")
        }
        return value
    }

    func userTableNames() throws -> [String] {
        let statement = try prepare(
            "SELECT name FROM sqlite_schema "
                + "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        var names: [String] = []
        while try statement.step() {
            guard let name = statement.text(at: 0) else {
                throw SQLiteStoreError.invalidState("sqlite_schema contained a NULL table name")
            }
            names.append(name)
        }
        return names
    }

    func setJournalModeWAL() throws {
        guard try querySingleText("PRAGMA journal_mode = WAL")?.lowercased() == "wal" else {
            throw SQLiteStoreError.invalidState("journal_mode did not read back as WAL")
        }
    }

    func foreignKeyViolationsExist() throws -> Bool {
        let statement = try prepare("PRAGMA foreign_key_check")
        return try statement.step()
    }

    private func requireIntegerPragma(_ name: String, equals expected: Int64) throws {
        guard try querySingleInt("PRAGMA \(name)") == expected else {
            throw SQLiteStoreError.invalidState("PRAGMA \(name) did not read back as \(expected)")
        }
    }

    private func currentError(operation: String) -> SQLiteStoreError {
        SQLiteStoreError.sqlite(
            operation: operation,
            code: sqlite3_extended_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
