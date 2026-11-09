//  SQLite 薄封装，移植自 shenshix/ShenShiCore/Sources/ShenShiCore/Support/SQLite.swift。
//
//  为什么不引第三方库：本地库的用法很窄（建表、带参执行、逐行读），为它引一个依赖等于把
//  「能不能编译」交给网络。参数一律走绑定，杜绝拼接注入。

import Foundation
import SQLite3

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    public static func text(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    public static func int(_ value: Int64?) -> SQLValue { value.map { .int($0) } ?? .null }
    public static func double(_ value: Double?) -> SQLValue { value.map { .double($0) } ?? .null }
    public static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
}

public struct SQLRow: Sendable {
    private var values: [String: SQLValue]

    init(_ values: [String: SQLValue]) { self.values = values }

    public subscript(key: String) -> SQLValue? { values[key] }

    public func int(_ key: String) -> Int64? {
        switch values[key] {
        case .int(let v): v
        case .double(let v): Int64(v)
        default: nil
        }
    }

    public func double(_ key: String) -> Double? {
        switch values[key] {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }

    public func text(_ key: String) -> String? {
        if case .text(let v) = values[key] { return v }
        return nil
    }

    public func bool(_ key: String) -> Bool { (int(key) ?? 0) != 0 }
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite 错误 \(code)：\(message)" }
}

/// 单连接、串行访问。单用户应用，并发压力只在「界面读写 + 后台引擎」两处，一把递归锁足够。
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let readOnly: Bool

    /// - Parameter readOnly: 只读打开（用于读旧版 state.db）。只读连接不能改 journal_mode，
    ///   所以跳过 WAL/synchronous 设置；WAL 库的 -shm 需要目录可写，由调用方保证。
    public init(path: String, readOnly: Bool = false) throws {
        self.readOnly = readOnly
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        try exec("PRAGMA busy_timeout=30000;")
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=NORMAL;")
            try exec("PRAGMA foreign_keys=ON;")
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    public func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "执行失败"
            if let err { sqlite3_free(err) }
            throw SQLiteError(code: rc, message: message)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
        }
        return sqlite3_last_insert_rowid(handle)
    }

    /// 单行查询，无结果返回 nil。
    public func queryOne(_ sql: String, _ params: [SQLValue] = []) throws -> SQLRow? {
        try query(sql, params).first
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(readRow(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
        return rows
    }

    /// 一个事务里跑一段写入；任何一步抛错就整体回滚。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try exec("COMMIT;")
            return value
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public var userVersion: Int32 {
        get {
            (try? queryOne("PRAGMA user_version;"))?.int("user_version").map(Int32.init) ?? 0
        }
        set { try? exec("PRAGMA user_version=\(newValue);") }
    }

    /// 最近一次 `run` 插入的行号。
    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    // MARK: - 内部

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else {
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [SQLValue]) throws {
        for (index, value) in params.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, position)
            case .int(let v): sqlite3_bind_int64(stmt, position, v)
            case .double(let v): sqlite3_bind_double(stmt, position, v)
            case .text(let v): sqlite3_bind_text(stmt, position, v, -1, SQLITE_TRANSIENT)
            }
        }
    }

    private func readRow(_ stmt: OpaquePointer?) -> SQLRow {
        var dict: [String: SQLValue] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER: dict[name] = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT: dict[name] = .double(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT:
                if let cstr = sqlite3_column_text(stmt, i) {
                    dict[name] = .text(String(cString: cstr))
                } else {
                    dict[name] = .null
                }
            default: dict[name] = .null
            }
        }
        return SQLRow(dict)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)