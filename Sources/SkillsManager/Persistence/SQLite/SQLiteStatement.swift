import Foundation
import SQLite3

nonisolated final class SQLiteStatement {
    private let statement: OpaquePointer

    init(statement: OpaquePointer) {
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bindNull(at index: Int32) throws {
        try requireBinding(sqlite3_bind_null(statement, index))
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try requireBinding(sqlite3_bind_int64(statement, index, value))
    }

    func bind(_ value: String, at index: Int32) throws {
        guard value.utf8.count <= Int(Int32.max) else {
            throw SQLiteStoreError.invalidState("text binding exceeds SQLite's byte limit")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient)
        }
        try requireBinding(result)
    }

    func bind(_ value: Data, at index: Int32) throws {
        guard value.count <= Int(Int32.max) else {
            throw SQLiteStoreError.invalidState("blob binding exceeds SQLite's byte limit")
        }
        if value.isEmpty {
            try requireBinding(sqlite3_bind_zeroblob(statement, index, 0))
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
        }
        try requireBinding(result)
    }

    /// Returns true for a row and false when execution is complete.
    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw currentError(operation: "step")
        }
    }

    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func text(at column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func blob(at column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    func reset() throws {
        let resetResult = sqlite3_reset(statement)
        let resetMessage = resetResult == SQLITE_OK
            ? nil
            : String(cString: sqlite3_errmsg(sqlite3_db_handle(statement)))
        let clearResult = sqlite3_clear_bindings(statement)
        guard clearResult == SQLITE_OK else {
            throw currentError(operation: "clear bindings")
        }
        if let resetMessage {
            throw SQLiteStoreError.sqlite(
                operation: "reset",
                code: resetResult,
                message: resetMessage
            )
        }
    }

    private func requireBinding(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw currentError(operation: "bind") }
    }

    private func currentError(operation: String) -> SQLiteStoreError {
        let database = sqlite3_db_handle(statement)
        return SQLiteStoreError.sqlite(
            operation: operation,
            code: sqlite3_extended_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
