import Foundation

/// schema 版本化。`PRAGMA user_version` 门控，迁移按序执行。
public enum Schema {
    public static let currentVersion: Int32 = 1

    /// 下标 0 对应版本 1。
    static let migrations: [String] = [v1]

    static let v1 = """
    CREATE TABLE IF NOT EXISTS tasks (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        raw_url         TEXT NOT NULL,
        task_key        TEXT NOT NULL UNIQUE,
        bvid            TEXT,
        title           TEXT,
        owner_name      TEXT,
        owner_mid       INTEGER,
        state           TEXT NOT NULL DEFAULT 'pending',
        attempts        INTEGER NOT NULL DEFAULT 0,
        backend         TEXT,
        error           TEXT,
        created_at      REAL NOT NULL,
        updated_at      REAL NOT NULL,
        source          TEXT NOT NULL DEFAULT 'icloud',
        subscription_id INTEGER,
        pubdate         REAL,
        duration        INTEGER,
        page_count      INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);
    CREATE INDEX IF NOT EXISTS idx_tasks_subscription ON tasks(subscription_id);

    CREATE TABLE IF NOT EXISTS task_outputs (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        path    TEXT NOT NULL,
        kind    TEXT NOT NULL DEFAULT 'video',
        bytes   INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_task_outputs_task ON task_outputs(task_id);

    CREATE TABLE IF NOT EXISTS subscriptions (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        mid                 INTEGER NOT NULL UNIQUE,
        name                TEXT,
        enabled             INTEGER NOT NULL DEFAULT 1,
        watermark           REAL,
        last_polled         REAL,
        consecutive_errors  INTEGER NOT NULL DEFAULT 0,
        disabled_reason     TEXT,
        initial_sync_done   INTEGER NOT NULL DEFAULT 0,
        created_at          REAL NOT NULL,
        updated_at          REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """

    /// 建表 + 迁移。幂等，可重复调用。
    public static func migrate(_ db: SQLiteDatabase) throws {
        let installed = db.userVersion
        guard installed < currentVersion else { return }
        try db.transaction {
            for version in (installed + 1)...currentVersion {
                let sql = migrations[Int(version) - 1]
                try db.exec(sql)
            }
            db.userVersion = currentVersion
        }
        Log.info("状态库迁移：\(installed) → \(currentVersion)")
    }
}
