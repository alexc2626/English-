import Foundation
import SQLite3

/// Minimal, strict wrapper over the system SQLite3 C API — just what the catalog needs:
/// prepared statements, typed binds/reads, transactions, and WAL mode. No ORM.
final class SQLiteDatabase {

    enum SQLiteError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)
        case bind(String)

        var description: String {
            switch self {
            case .open(let m): return "SQLite open failed: \(m)"
            case .prepare(let m, let sql): return "SQLite prepare failed: \(m) — \(sql)"
            case .step(let m, let sql): return "SQLite step failed: \(m) — \(sql)"
            case .bind(let m): return "SQLite bind failed: \(m)"
            }
        }
    }

    private var db: OpaquePointer?
    let path: String

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        // WAL keeps readers unblocked during background imports; NORMAL sync is safe with WAL.
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close_v2(db)
    }

    private var lastMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    // MARK: Statements

    /// A prepared statement bound to positional values. Values may be
    /// Int / Int64 / Double / String / Data / UUID / Date / Bool / nil.
    func execute(_ sql: String, _ values: [Any?] = []) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step(lastMessage, sql: sql)
        }
    }

    /// Run a query, mapping each row through `transform`.
    func query<T>(_ sql: String, _ values: [Any?] = [],
                  _ transform: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(try transform(Row(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.step(lastMessage, sql: sql)
            }
        }
        return out
    }

    func queryOne<T>(_ sql: String, _ values: [Any?] = [],
                     _ transform: (Row) throws -> T) throws -> T? {
        try query(sql, values, transform).first
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    private func prepare(_ sql: String, _ values: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(lastMessage, sql: sql)
        }
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case nil:
                rc = sqlite3_bind_null(stmt, idx)
            case let v as Int:
                rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:
                rc = sqlite3_bind_int64(stmt, idx, v)
            case let v as Double:
                rc = sqlite3_bind_double(stmt, idx, v)
            case let v as Bool:
                rc = sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as String:
                rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transientDestructor)
            case let v as UUID:
                rc = sqlite3_bind_text(stmt, idx, v.uuidString, -1, Self.transientDestructor)
            case let v as Date:
                rc = sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            case let v as Data:
                rc = v.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count),
                                      Self.transientDestructor)
                }
            default:
                sqlite3_finalize(stmt)
                throw SQLiteError.bind("unsupported bind type at index \(idx)")
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw SQLiteError.bind(lastMessage)
            }
        }
        return stmt
    }

    // MARK: Row access

    struct Row {
        let stmt: OpaquePointer

        func int(_ col: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(col)) }
        func double(_ col: Int) -> Double { sqlite3_column_double(stmt, Int32(col)) }
        func bool(_ col: Int) -> Bool { sqlite3_column_int64(stmt, Int32(col)) != 0 }

        func string(_ col: Int) -> String? {
            sqlite3_column_text(stmt, Int32(col)).map { String(cString: $0) }
        }

        func uuid(_ col: Int) -> UUID? {
            string(col).flatMap(UUID.init(uuidString:))
        }

        func date(_ col: Int) -> Date? {
            sqlite3_column_type(stmt, Int32(col)) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: double(col))
        }

        func data(_ col: Int) -> Data? {
            guard let bytes = sqlite3_column_blob(stmt, Int32(col)) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, Int32(col)))
            return Data(bytes: bytes, count: count)
        }

        func optionalInt(_ col: Int) -> Int64? {
            sqlite3_column_type(stmt, Int32(col)) == SQLITE_NULL ? nil : int(col)
        }

        func optionalDouble(_ col: Int) -> Double? {
            sqlite3_column_type(stmt, Int32(col)) == SQLITE_NULL ? nil : double(col)
        }
    }
}
