import Foundation

public struct Subscription: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var mid: Int64
    public var name: String?
    public var enabled: Bool
    /// 已入队稿件的最新发布时间。增量判断用 `created > watermark`。
    public var watermark: Date?
    public var lastPolled: Date?
    public var consecutiveErrors: Int
    public var disabledReason: String?
    /// 首次同步只记水位、不灌历史投稿。
    public var initialSyncDone: Bool
    public var capturedCount: Int

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return "UP \(mid)"
    }
}

/// 订阅表。与任务表共用同一个 SQLiteDatabase（线程安全），所以不另开连接。
public actor SubscriptionStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func all() throws -> [Subscription] {
        let rows = try database.query("""
        SELECT s.*, (SELECT COUNT(*) FROM tasks t WHERE t.subscription_id = s.id) AS captured
        FROM subscriptions s ORDER BY s.id;
        """)
        return rows.map(Self.subscription(from:))
    }

    public func subscription(id: Int64) throws -> Subscription? {
        guard let row = try database.queryOne("""
        SELECT s.*, (SELECT COUNT(*) FROM tasks t WHERE t.subscription_id = s.id) AS captured
        FROM subscriptions s WHERE s.id = ?;
        """, [.int(id)]) else { return nil }
        return Self.subscription(from: row)
    }

    /// 新增订阅。已存在同 mid 时返回 nil。
    @discardableResult
    public func add(mid: Int64, name: String?) throws -> Int64? {
        if try database.queryOne("SELECT id FROM subscriptions WHERE mid = ?;", [.int(mid)]) != nil {
            return nil
        }
        let now = Date().timeIntervalSince1970
        try database.run(
            """
            INSERT INTO subscriptions (mid, name, enabled, created_at, updated_at)
            VALUES (?, ?, 1, ?, ?);
            """,
            [.int(mid), .text(name), .double(now), .double(now)]
        )
        return database.lastInsertRowID
    }

    public func remove(id: Int64) throws {
        try database.run("DELETE FROM subscriptions WHERE id = ?;", [.int(id)])
    }

    public func setEnabled(id: Int64, enabled: Bool) throws {
        try database.run(
            """
            UPDATE subscriptions SET enabled = ?, consecutive_errors = 0,
                disabled_reason = NULL, updated_at = ? WHERE id = ?;
            """,
            [.bool(enabled), .double(Date().timeIntervalSince1970), .int(id)]
        )
    }

    public func updateName(id: Int64, name: String) throws {
        try database.run(
            "UPDATE subscriptions SET name = ?, updated_at = ? WHERE id = ?;",
            [.text(name), .double(Date().timeIntervalSince1970), .int(id)]
        )
    }

    public func recordSuccess(id: Int64, watermark: Date?, initialSyncDone: Bool) throws {
        let now = Date().timeIntervalSince1970
        try database.run(
            """
            UPDATE subscriptions SET
                watermark = COALESCE(?, watermark),
                last_polled = ?, consecutive_errors = 0, disabled_reason = NULL,
                initial_sync_done = ?, updated_at = ?
            WHERE id = ?;
            """,
            [
                .double(watermark?.timeIntervalSince1970), .double(now),
                .bool(initialSyncDone), .double(now), .int(id),
            ]
        )
    }

    /// - Parameter disable: 连续失败达到阈值时自动停用并记原因（熔断）。
    public func recordFailure(id: Int64, error: String, disable: Bool) throws {
        let now = Date().timeIntervalSince1970
        let current = try database.queryOne(
            "SELECT consecutive_errors FROM subscriptions WHERE id = ?;", [.int(id)]
        )?.int("consecutive_errors") ?? 0
        try database.run(
            """
            UPDATE subscriptions SET
                last_polled = ?, consecutive_errors = ?,
                enabled = ?, disabled_reason = ?, updated_at = ?
            WHERE id = ?;
            """,
            [
                .double(now), .int(current + 1),
                .bool(!disable), .text(String(error.prefix(300))), .double(now), .int(id),
            ]
        )
    }

    static func subscription(from row: SQLRow) -> Subscription {
        Subscription(
            id: row.int("id") ?? 0,
            mid: row.int("mid") ?? 0,
            name: row.text("name"),
            enabled: row.bool("enabled"),
            watermark: row.double("watermark").map(Date.init(timeIntervalSince1970:)),
            lastPolled: row.double("last_polled").map(Date.init(timeIntervalSince1970:)),
            consecutiveErrors: Int(row.int("consecutive_errors") ?? 0),
            disabledReason: row.text("disabled_reason"),
            initialSyncDone: row.bool("initial_sync_done"),
            capturedCount: Int(row.int("captured") ?? 0)
        )
    }
}