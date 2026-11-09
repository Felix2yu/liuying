import Foundation

/// 只读旧 Python 版的 state.db。
///
/// 用途仅一个：首次启动时知道哪些视频已经下过，从 links.txt 里把这些链接清掉。
/// 按用户决策**不把旧记录导入新库** —— 新库是全新的。代价是重新分享一个旧 BV 会再入队一次，
/// 但 yutto 默认跳过已存在文件（未加 -w/--overwrite），实际开销很小。
public enum LegacyReader {
    public struct LegacyTask: Sendable, Hashable {
        public var taskKey: String
        public var rawURL: String

        public init(taskKey: String, rawURL: String) {
            self.taskKey = taskKey
            self.rawURL = rawURL
        }
    }

    /// 旧库里 state='done' 的记录。库不存在、表不存在或读取失败都返回空数组（不阻断启动）。
    public static func completedTasks(databasePath: String = AppIdentity.legacyDatabasePath) -> [LegacyTask] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        do {
            let db = try SQLiteDatabase(path: databasePath, readOnly: true)
            let rows = try db.query(
                "SELECT task_key, raw_url FROM tasks WHERE state = 'done';"
            )
            return rows.compactMap { row in
                guard let key = row.text("task_key"), !key.isEmpty else { return nil }
                return LegacyTask(taskKey: key, rawURL: row.text("raw_url") ?? "")
            }
        } catch {
            Log.warning("读取旧状态库失败（忽略）：\(error)")
            return []
        }
    }

    /// 旧库里已完成的去重键，同时包含 task_key 与 raw_url，
    /// 这样 links.txt 里无论是短链还是完整链接都能被清掉。
    public static func completedKeys(databasePath: String = AppIdentity.legacyDatabasePath) -> Set<String> {
        var keys = Set<String>()
        for task in completedTasks(databasePath: databasePath) {
            keys.insert(task.taskKey)
            if !task.rawURL.isEmpty { keys.insert(task.rawURL) }
        }
        return keys
    }
}