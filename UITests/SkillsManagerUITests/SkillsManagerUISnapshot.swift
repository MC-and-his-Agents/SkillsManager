import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest

struct SkillsManagerUISnapshot: Equatable {
    let sqliteTables: [String: [String]]
    let ssotDigest: String
    let agentTargets: [String: AgentTargetEntry]
    let bindingRows: [String]

    struct AgentTargetEntry: Equatable {
        let mode: mode_t
        let device: UInt64
        let inode: UInt64
        let target: String?
    }

    static func capture(home: URL) throws -> SkillsManagerUISnapshot {
        let management = home.appendingPathComponent(".SkillsManager", isDirectory: true)
        let database = management.appendingPathComponent("manager.sqlite")
        let ssot = management.appendingPathComponent("skills", isDirectory: true)
        let agentSkills = home.appendingPathComponent(".agents/skills", isDirectory: true)
        var sqliteTables: [String: [String]] = [:]
        var bindingRows: [String] = []
        if FileManager.default.fileExists(atPath: database.path) {
            sqliteTables = try readSQLiteTables(at: database)
            bindingRows = sqliteTables["distribution_bindings"] ?? []
        }
        return SkillsManagerUISnapshot(
            sqliteTables: sqliteTables,
            ssotDigest: try treeDigest(at: ssot),
            agentTargets: try readAgentTargets(at: agentSkills),
            bindingRows: bindingRows
        )
    }

    func describeDifferences(against other: SkillsManagerUISnapshot) -> [String] {        var differences: [String] = []
        if sqliteTables != other.sqliteTables {
            differences.append("SQLite tables changed")
            for key in Set(sqliteTables.keys).union(other.sqliteTables.keys) {
                if sqliteTables[key] != other.sqliteTables[key] {
                    differences.append("  table \(key): before \(other.sqliteTables[key]?.count ?? 0) rows, after \(sqliteTables[key]?.count ?? 0) rows")
                }
            }
        }
        if ssotDigest != other.ssotDigest {
            differences.append("SSOT tree/content digest changed")
        }
        if agentTargets != other.agentTargets {
            differences.append("Agent target identities changed")
        }
        if bindingRows != other.bindingRows {
            differences.append("Distribution bindings changed")
        }
        return differences
    }

    private static func readSQLiteTables(at url: URL) throws -> [String: [String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { sqlite3_close(database) }
        let tables = try queryStrings(database, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        var result: [String: [String]] = [:]
        for table in tables {
            let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
            result[table] = try queryRows(database, "SELECT rowid, * FROM \"\(escaped)\" ORDER BY rowid")
        }
        return result
    }

    private static func queryStrings(_ database: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return values
    }

    private static func queryRows(_ database: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        if columnCount > 0 {
            for column in Int32(0)..<Int32(columnCount) {
                names.append(String(cString: sqlite3_column_name(statement, column)))
            }
        }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var fields: [String] = ["rowid=\(sqlite3_column_int64(statement, 0))"]
            if columnCount > 1 {
                for column in Int32(1)..<Int32(columnCount) {
                    let value: String
                    if sqlite3_column_type(statement, column) == SQLITE_NULL {
                        value = "NULL"
                    } else if let text = sqlite3_column_text(statement, column) {
                        value = String(cString: text)
                    } else {
                        value = "\(sqlite3_column_int64(statement, column))"
                    }
                    fields.append("\(names[Int(column)])=\(value)")
                }
            }
            rows.append(fields.joined(separator: "|"))
        }
        return rows
    }

    private static func treeDigest(at url: URL) throws -> String {
        var hasher = SHA256()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return Data(hasher.finalize()).hexString
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var relativePaths: [String] = []
        for case let item as URL in enumerator {
            let relative = item.path.replacingOccurrences(of: url.path + "/", with: "")
            relativePaths.append(relative)
        }
        for relative in relativePaths.sorted() {
            let item = url.appendingPathComponent(relative)
            var metadata = stat()
            guard Darwin.lstat(item.path, &metadata) == 0 else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            var bytes = Data(("path:\(relative)\nmode:\(String(metadata.st_mode, radix: 8))\n".utf8))
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                bytes.append(Data("target:\(target)\n".utf8))
            } else if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      let content = fileManager.contents(atPath: item.path) {
                bytes.append(content)
            }
            hasher.update(data: bytes)
        }
        return Data(hasher.finalize()).hexString
    }

    private static func readAgentTargets(at url: URL) throws -> [String: AgentTargetEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let names = try fileManager.contentsOfDirectory(atPath: url.path).sorted()
        var entries: [String: AgentTargetEntry] = [:]
        for name in names {
            let item = url.appendingPathComponent(name)
            var metadata = stat()
            guard Darwin.lstat(item.path, &metadata) == 0 else { continue }
            let target: String?
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                target = try? fileManager.destinationOfSymbolicLink(atPath: item.path)
            } else {
                target = nil
            }
            entries[name] = AgentTargetEntry(
                mode: mode_t(metadata.st_mode & 0o7777),
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino),
                target: target
            )
        }
        return entries
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension SkillsManagerUISnapshot {
    var managedSkillNames: [String] {
        (sqliteTables["skills"] ?? []).compactMap { row in
            row.split(separator: "|").first {
                $0.hasPrefix("display_name=")
            }.map { String($0.dropFirst("display_name=".count)) }
        }
    }

    var managedSkillCount: Int { managedSkillNames.count }

    var agentTargetNames: [String] {
        Array(agentTargets.keys).sorted()
    }
}
