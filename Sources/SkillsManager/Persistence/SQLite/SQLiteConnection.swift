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

    init(
        path: String,
        accessMode: SQLiteAccessMode = .readWrite,
        expectedParentIdentity: ManagedItemIdentity? = nil,
        afterNamedIdentityRead: () throws -> Void = {}
    ) throws {
        var opened: OpaquePointer?
        let databaseURL = URL(fileURLWithPath: path)
        let databaseName = databaseURL.lastPathComponent
        let parentDescriptor = try Self.openDatabaseDirectory(
            databaseURL.deletingLastPathComponent().path
        )
        defer { Darwin.close(parentDescriptor) }
        if let expectedParentIdentity {
            var parentMetadata = stat()
            guard Darwin.fstat(parentDescriptor, &parentMetadata) == 0,
                  ManagedItemIdentity(parentMetadata) == expectedParentIdentity else {
                throw SQLiteStoreError.invalidState("database directory identity changed")
            }
        }
        let namedIdentity = try Self.databaseIdentity(
            named: databaseName,
            parentDescriptor: parentDescriptor
        )
        try afterNamedIdentityRead()
        let expectedIdentity: ManagedItemIdentity?
        if accessMode == .readWrite, namedIdentity == nil {
            expectedIdentity = try Self.createDatabaseFile(
                named: databaseName,
                parentDescriptor: parentDescriptor
            )
        } else {
            expectedIdentity = namedIdentity
        }
        let openPath = try Self.databasePath(
            named: databaseName,
            parentDescriptor: parentDescriptor
        )
        let flags: Int32 = switch accessMode {
        case .readWrite:
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
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
        do {
            guard let openedIdentity = try Self.databaseIdentity(at: openPath),
                  try Self.databaseIdentity(
                    named: databaseName,
                    parentDescriptor: parentDescriptor
                  ) == openedIdentity,
                  expectedIdentity == openedIdentity else {
                throw SQLiteStoreError.invalidState("database identity changed during open")
            }
        } catch {
            sqlite3_close_v2(opened)
            throw error
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

    private static func openDatabaseDirectory(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let code = errno
            throw SQLiteStoreError.sqlite(
                operation: "open database directory",
                code: code,
                message: String(cString: strerror(code))
            )
        }
        return descriptor
    }

    private static func createDatabaseFile(
        named name: String,
        parentDescriptor: Int32
    ) throws -> ManagedItemIdentity {
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            let code = errno
            throw SQLiteStoreError.sqlite(
                operation: "create database file",
                code: code,
                message: String(cString: strerror(code))
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            let code = errno
            throw SQLiteStoreError.sqlite(
                operation: "set database file permissions",
                code: code,
                message: String(cString: strerror(code))
            )
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw SQLiteStoreError.invalidState("created database file is invalid")
        }
        return ManagedItemIdentity(metadata)
    }

    private static func databaseIdentity(
        named name: String,
        parentDescriptor: Int32
    ) throws -> ManagedItemIdentity? {
        var metadata = stat()
        if Darwin.fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                throw SQLiteStoreError.invalidState("database path must be a regular file")
            }
            return ManagedItemIdentity(metadata)
        }
        let code = errno
        guard code == ENOENT else {
            throw SQLiteStoreError.sqlite(
                operation: "inspect database path",
                code: code,
                message: String(cString: strerror(code))
            )
        }
        return nil
    }

    private static func databaseIdentity(at path: String) throws -> ManagedItemIdentity? {
        var metadata = stat()
        if Darwin.lstat(path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                throw SQLiteStoreError.invalidState("database path must be a regular file")
            }
            return ManagedItemIdentity(metadata)
        }

        let code = errno
        guard code == ENOENT else {
            throw SQLiteStoreError.sqlite(
                operation: "inspect database path",
                code: code,
                message: String(cString: strerror(code))
            )
        }
        return nil
    }

    private static func databasePath(
        named name: String,
        parentDescriptor: Int32
    ) throws -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(parentDescriptor, F_GETPATH, &path) != -1 else {
            let code = errno
            throw SQLiteStoreError.sqlite(
                operation: "resolve database directory descriptor",
                code: code,
                message: String(cString: strerror(code))
            )
        }
        let directoryPath = String(
            decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(
            fileURLWithPath: directoryPath,
            isDirectory: true
        )
        .appendingPathComponent(name)
        .path
    }

    convenience init(
        url: URL,
        accessMode: SQLiteAccessMode = .readWrite,
        expectedParentIdentity: ManagedItemIdentity? = nil
    ) throws {
        try self.init(
            path: url.path,
            accessMode: accessMode,
            expectedParentIdentity: expectedParentIdentity
        )
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
