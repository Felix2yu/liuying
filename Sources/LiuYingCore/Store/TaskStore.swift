import Foundation

/// 任务状态库。全新独立 schema，不读写旧 Python 版的 state.db（那个只由 LegacyReader 只读打开）。
public actor TaskStore {
    public nonisolated let database: SQLiteDatabase

    public init(database: SQLiteDatabase) throws {
        self.database = database
        try Schema.migrate(database)
    }

    public init(path: String = AppIdentity.databasePath) throws {
        self.database = try SQLiteDatabase(path: path)
        try Schema.migrate(self.database)
    }

    // MARK: - 去重与入队

    public func knownKeys() throws -> Set<String> {
        Set(try database.query("SELECT task_key FROM tasks;").compactMap { $0.text("task_key") })
    }

    /// 已存在同名 key 则返回 nil。
    @discardableResult
    public func add(_ task: NewTask) throws -> Int64? {
        try database.transaction {
            if try database.queryOne(
                "SELECT id FROM tasks WHERE task_key = ?;", [.text(task.taskKey)]
            ) != nil {
                return nil
            }
            let now = Date().timeIntervalSince1970
            try database.run(
                """
                INSERT INTO tasks
                    (raw_url, task_key, bvid, title, owner_name, owner_mid, state,
                     created_at, updated_at, source, subscription_id, pubdate, duration, page_count)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .text(task.rawURL), .text(task.taskKey), .text(task.bvid), .text(task.title),
                    .text(task.ownerName), .int(task.ownerMid), .double(now), .double(now),
                    .text(task.source.rawValue), .int(task.subscriptionID),
                    .double(task.pubdate?.timeIntervalSince1970), .int(task.duration.map(Int64.init)),
                    .int(task.pageCount.map(Int64.init)),
                ]
            )
            return database.lastInsertRowID
        }
    }

    /// 批量入队，返回真正新增的条数（已存在的 key 跳过）。
    @discardableResult
    public func addBatch(_ tasks: [NewTask]) throws -> Int {
        var added = 0
        for task in tasks where (try add(task)) != nil { added += 1 }
        return added
    }

    // MARK: - 领取与收尾

    /// 取出待处理任务并标记为 downloading，attempts+1。
    /// 返回的 DownloadTask 已反映**递增后**的 attempts ——
    /// 旧版在 claim 里 +1、又在 process 里用 `row.attempts + 1` 判断，导致实际只重试 2 次。
    public func claim(limit: Int) throws -> [DownloadTask] {
        guard limit > 0 else { return [] }
        let claimed: [DownloadTask] = try database.transaction {
            let rows = try database.query(
                "SELECT * FROM tasks WHERE state = 'pending' ORDER BY id LIMIT ?;",
                [.int(Int64(limit))]
            )
            guard !rows.isEmpty else { return [] }
            let now = Date().timeIntervalSince1970
            for row in rows {
                guard let id = row.int("id") else { continue }
                try database.run(
                    """
                    UPDATE tasks SET state = 'downloading', attempts = attempts + 1, updated_at = ?
                    WHERE id = ?;
                    """,
                    [.double(now), .int(id)]
                )
            }
            return rows.compactMap { row in
                var task = Self.task(from: row)
                task.attempts += 1
                task.state = .downloading
                task.updatedAt = Date(timeIntervalSince1970: now)
                return task
            }
        }
        return try attachOutputs(claimed)
    }

    /// 完成/失败收尾。outputs 会整体替换该任务的产出列表。
    public func finish(
        id: Int64,
        state: TaskState,
        outputs: [TaskOutput] = [],
        error: String? = nil,
        backend: String? = nil,
        title: String? = nil,
        ownerName: String? = nil,
        bvid: String? = nil
    ) throws {
        try database.transaction {
            try database.run(
                """
                UPDATE tasks SET
                    state = ?, error = ?, backend = ?,
                    title = COALESCE(NULLIF(?, ''), title),
                    owner_name = COALESCE(NULLIF(?, ''), owner_name),
                    bvid = COALESCE(NULLIF(?, ''), bvid),
                    updated_at = ?
                WHERE id = ?;
                """,
                [
                    .text(state.rawValue), .text(error), .text(backend),
                    .text(title ?? ""), .text(ownerName ?? ""), .text(bvid ?? ""),
                    .double(Date().timeIntervalSince1970), .int(id),
                ]
            )
            try database.run("DELETE FROM task_outputs WHERE task_id = ?;", [.int(id)])
            for output in outputs {
                try database.run(
                    "INSERT INTO task_outputs (task_id, path, kind, bytes) VALUES (?, ?, ?, ?);",
                    [.int(id), .text(output.path), .text(output.kind), .int(output.bytes)]
                )
            }
        }
    }

    public func retryLater(id: Int64, error: String) throws {
        try database.run(
            "UPDATE tasks SET state = 'pending', error = ?, updated_at = ? WHERE id = ?;",
            [.text(String(error.prefix(500))), .double(Date().timeIntervalSince1970), .int(id)]
        )
    }

    /// 启动时调用：把上次崩溃/强退留下的 downloading 放回 pending。
    @discardableResult
    public func recoverInterrupted() throws -> Int {
        let rows = try database.query("SELECT id FROM tasks WHERE state = 'downloading';")
        guard !rows.isEmpty else { return 0 }
        try database.run(
            """
            UPDATE tasks SET state = 'pending', error = '上次运行被中断，已重新排队', updated_at = ?
            WHERE state = 'downloading';
            """,
            [.double(Date().timeIntervalSince1970)]
        )
        return rows.count
    }

    // MARK: - 界面操作

    /// 重新下载：回到 pending 并清零 attempts。
    public func requeue(id: Int64) throws {
        try database.run(
            """
            UPDATE tasks SET state = 'pending', attempts = 0, error = NULL, updated_at = ?
            WHERE id = ?;
            """,
            [.double(Date().timeIntervalSince1970), .int(id)]
        )
    }

    /// 仅允许删掉不处于 downloading 的任务，避免把正在下载的行抽走。
    public func delete(id: Int64) throws {
        try database.run(
            "DELETE FROM tasks WHERE id = ? AND state != 'downloading';", [.int(id)]
        )
    }

    public func forceFail(id: Int64, error: String) throws {
        try database.run(
            "UPDATE tasks SET state = 'failed', error = ?, updated_at = ? WHERE id = ?;",
            [.text(error), .double(Date().timeIntervalSince1970), .int(id)]
        )
    }

    /// 下载成功后回填元数据（B 站 view 接口，尽力而为）。
    public func setMetadata(
        id: Int64, bvid: String?, title: String?, ownerName: String?,
        ownerMid: Int64?, duration: Int?, pageCount: Int?
    ) throws {
        try database.run(
            """
            UPDATE tasks SET
                bvid = COALESCE(NULLIF(?, ''), bvid),
                title = COALESCE(NULLIF(?, ''), title),
                owner_name = COALESCE(NULLIF(?, ''), owner_name),
                owner_mid = COALESCE(?, owner_mid),
                duration = COALESCE(?, duration),
                page_count = COALESCE(?, page_count),
                updated_at = ?
            WHERE id = ?;
            """,
            [
                .text(bvid ?? ""), .text(title ?? ""), .text(ownerName ?? ""),
                .int(ownerMid), .int(duration.map(Int64.init)), .int(pageCount.map(Int64.init)),
                .double(Date().timeIntervalSince1970), .int(id),
            ]
        )
    }

    // MARK: - 查询

    public func stats() throws -> [TaskState: Int] {
        var result: [TaskState: Int] = [:]
        for state in TaskState.allCases { result[state] = 0 }
        for row in try database.query("SELECT state, COUNT(*) AS n FROM tasks GROUP BY state;") {
            guard let raw = row.text("state"), let state = TaskState(rawValue: raw) else { continue }
            result[state] = Int(row.int("n") ?? 0)
        }
        return result
    }

    public func recent(limit: Int = 50) throws -> [DownloadTask] {
        try attachOutputs(
            try database.query(
                "SELECT * FROM tasks ORDER BY id DESC LIMIT ?;", [.int(Int64(limit))]
            ).map(Self.task(from:))
        )
    }

    public func tasks(in states: [TaskState], limit: Int = 200) throws -> [DownloadTask] {
        guard !states.isEmpty else { return [] }
        let placeholders = states.map { _ in "?" }.joined(separator: ",")
        let rows = try database.query(
            "SELECT * FROM tasks WHERE state IN (\(placeholders)) ORDER BY id DESC LIMIT ?;",
            states.map { .text($0.rawValue) } + [.int(Int64(limit))]
        )
        return try attachOutputs(rows.map(Self.task(from:)))
    }

    public func task(id: Int64) throws -> DownloadTask? {
        guard let row = try database.queryOne("SELECT * FROM tasks WHERE id = ?;", [.int(id)]) else {
            return nil
        }
        return try attachOutputs([Self.task(from: row)]).first
    }

    /// 订阅已捕获的视频数。
    public func countForSubscription(_ subscriptionID: Int64) throws -> Int {
        Int(try database.queryOne(
            "SELECT COUNT(*) AS n FROM tasks WHERE subscription_id = ?;", [.int(subscriptionID)]
        )?.int("n") ?? 0)
    }

    // MARK: - 行映射

    static func task(from row: SQLRow) -> DownloadTask {
        DownloadTask(
            id: row.int("id") ?? 0,
            rawURL: row.text("raw_url") ?? "",
            taskKey: row.text("task_key") ?? "",
            bvid: row.text("bvid"),
            title: row.text("title"),
            ownerName: row.text("owner_name"),
            ownerMid: row.int("owner_mid"),
            state: TaskState(rawValue: row.text("state") ?? "pending") ?? .pending,
            attempts: Int(row.int("attempts") ?? 0),
            backend: row.text("backend"),
            error: row.text("error"),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0),
            source: TaskSource(rawValue: row.text("source") ?? "icloud") ?? .icloud,
            subscriptionID: row.int("subscription_id"),
            pubdate: row.double("pubdate").map(Date.init(timeIntervalSince1970:)),
            duration: row.int("duration").map(Int.init),
            pageCount: row.int("page_count").map(Int.init),
            outputs: []
        )
    }

    private func attachOutputs(_ tasks: [DownloadTask]) throws -> [DownloadTask] {
        guard !tasks.isEmpty else { return tasks }
        let ids = tasks.map(\.id)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try database.query(
            "SELECT * FROM task_outputs WHERE task_id IN (\(placeholders)) ORDER BY id;",
            ids.map { .int($0) }
        )
        var byTask: [Int64: [TaskOutput]] = [:]
        for row in rows {
            guard let taskID = row.int("task_id") else { continue }
            byTask[taskID, default: []].append(TaskOutput(
                id: row.int("id") ?? 0,
                taskID: taskID,
                path: row.text("path") ?? "",
                kind: row.text("kind") ?? "video",
                bytes: row.int("bytes")
            ))
        }
        return tasks.map { task in
            var copy = task
            copy.outputs = byTask[task.id] ?? []
            return copy
        }
    }
}