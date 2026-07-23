import Darwin
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
    case readWriteExisting
    case readOnly
}

/// The composition root transfers each full-mutex connection to one serial owner.
nonisolated final class SQLiteConnection: @unchecked Sendable {
    private let database: OpaquePointer
    let accessMode: SQLiteAccessMode

    init(path: String, accessMode: SQLiteAccessMode = .readWrite) throws {
        var opened: OpaquePointer?
        let databaseExists = try Self.pathExistsWithoutFollowingSymlinks(path)
        let openPath = try Self.resolvedDatabasePath(path)
        let existingDatabaseFlag: Int32
        if accessMode == .readWrite {
            existingDatabaseFlag = databaseExists ? SQLITE_OPEN_NOFOLLOW : 0
        } else {
            existingDatabaseFlag = SQLITE_OPEN_NOFOLLOW
        }
        let flags: Int32 = switch accessMode {
        case .readWrite:
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                | existingDatabaseFlag
        case .readWriteExisting:
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        case .readOnly:
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        }
        let result = sqlite3_open_v2(openPath, &opened, flags, nil)
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
            case .readWrite, .readWriteExisting:
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

    private static func pathExistsWithoutFollowingSymlinks(_ path: String) throws -> Bool {
        var metadata = stat()
        if Darwin.lstat(path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT != S_IFLNK else {
                throw SQLiteStoreError.invalidState("database path must not be a symbolic link")
            }
            return true
        }

        let code = errno
        guard code == ENOENT else {
            throw SQLiteStoreError.sqlite(
                operation: "inspect database path",
                code: code,
                message: String(cString: strerror(code))
            )
        }
        return false
    }

    private static func resolvedDatabasePath(_ path: String) throws -> String {
        let databaseURL = URL(fileURLWithPath: path)
        guard let resolvedParent = Darwin.realpath(
            databaseURL.deletingLastPathComponent().path,
            nil
        ) else {
            let code = errno
            throw SQLiteStoreError.sqlite(
                operation: "resolve database directory",
                code: code,
                message: String(cString: strerror(code))
            )
        }
        defer { Darwin.free(resolvedParent) }
        return URL(
            fileURLWithPath: String(cString: resolvedParent),
            isDirectory: true
        )
        .appendingPathComponent(databaseURL.lastPathComponent)
        .path
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
