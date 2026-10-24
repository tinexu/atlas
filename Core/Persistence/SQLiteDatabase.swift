import Foundation
import SQLite3

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case bind(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "Couldn't open the ATLAS database: \(message)"
        case .prepare(let message, let sql): return "SQL error: \(message) in \(sql)"
        case .step(let message, let sql): return "SQL error: \(message) in \(sql)"
        case .bind(let message): return "SQL bind error: \(message)"
        }
    }
}

public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// One result row, addressed by column name.
public struct SQLRow {
    public let columns: [String: SQLValue]

    public func string(_ name: String) -> String? {
        if case .text(let s) = columns[name] { return s }
        return nil
    }

    public func int(_ name: String) -> Int? {
        switch columns[name] {
        case .integer(let i): return Int(i)
        case .real(let d): return Int(d)
        default: return nil
        }
    }

    public func double(_ name: String) -> Double? {
        switch columns[name] {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    public func bool(_ name: String) -> Bool? { int(name).map { $0 != 0 } }

    public func date(_ name: String) -> Date? { double(name).map(Date.init(timeIntervalSince1970:)) }

    public func uuid(_ name: String) -> UUID? { string(name).flatMap(UUID.init(uuidString:)) }
}

/// A deliberately small wrapper over the SQLite C API. All access is
/// serialised through one recursive lock, which is plenty for a local
/// configuration store and keeps transactions simple.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    /// Pass ":memory:" for a throwaway database (tests).
    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            handle = nil
            throw DatabaseError.open(message)
        }
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA foreign_keys = ON;")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL;")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
    }

    /// Runs one or more statements with no bindings and no results.
    public func execute(_ sql: String) throws {
        try withLock {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? errorMessage
                sqlite3_free(error)
                throw DatabaseError.step(message, sql: sql)
            }
        }
    }

    /// Runs a single statement that returns no rows.
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try withStatement(sql, bindings) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE || code == SQLITE_ROW else {
                throw DatabaseError.step(errorMessage, sql: sql)
            }
        }
    }

    /// Runs a single query and returns every row.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        try withStatement(sql, bindings) { statement in
            var rows: [SQLRow] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw DatabaseError.step(errorMessage, sql: sql) }
                var columns: [String: SQLValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    columns[name] = Self.value(of: statement, at: index)
                }
                rows.append(SQLRow(columns: columns))
            }
            return rows
        }
    }

    /// Wraps `body` in a transaction, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            try execute("BEGIN IMMEDIATE;")
            do {
                let result = try body()
                try execute("COMMIT;")
                return result
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    public var userVersion: Int {
        (try? query("PRAGMA user_version;").first?.int("user_version")) ?? 0
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    // MARK: Internals

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func withStatement<T>(_ sql: String, _ bindings: [SQLValue], _ body: (OpaquePointer?) throws -> T) throws -> T {
        try withLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.prepare(errorMessage, sql: sql)
            }
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            return try body(statement)
        }
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let i):
                code = sqlite3_bind_int64(statement, index, i)
            case .real(let d):
                code = sqlite3_bind_double(statement, index, d)
            case .text(let s):
                code = sqlite3_bind_text(statement, index, s, -1, sqliteTransient)
            case .blob(let data):
                code = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            }
            guard code == SQLITE_OK else { throw DatabaseError.bind(errorMessage) }
        }
    }

    private static func value(of statement: OpaquePointer?, at index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_blob(statement, index), count > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}

/// Tells SQLite to copy bound strings/blobs immediately.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Binding conveniences

extension SQLValue {
    public static func from(_ string: String?) -> SQLValue { string.map(SQLValue.text) ?? .null }
    public static func from(_ date: Date?) -> SQLValue { date.map { .real($0.timeIntervalSince1970) } ?? .null }
    public static func from(_ double: Double?) -> SQLValue { double.map(SQLValue.real) ?? .null }
    public static func from(_ bool: Bool) -> SQLValue { .integer(bool ? 1 : 0) }
    public static func from(_ int: Int) -> SQLValue { .integer(Int64(int)) }
    public static func from(_ uuid: UUID) -> SQLValue { .text(uuid.uuidString) }
}
