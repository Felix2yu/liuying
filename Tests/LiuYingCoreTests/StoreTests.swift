import XCTest
@testable import LiuYingCore

final class TaskStoreTests: XCTestCase {
    private var directory: String!
    private var path: String!
    private var store: TaskStore!

    override func setUp() async throws {
        directory = NSTemporaryDirectory() + "liuying-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = (directory as NSString).appendingPathComponent("state.db")
        store = try TaskStore(path: path)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// XCTUnwrap / XCTAssert* 都是 @autoclosure，不能在里面 await，所以统一在这里落成具体值。
    private func addTask(_ key: String, title: String? = nil) async throws -> Int64 {
        let id = try await store.add(newTask(key, title: title))
        return try XCTUnwrap(id)
    }

    private func loadTask(_ id: Int64) async throws -> DownloadTask {
        let maybe = try await store.task(id: id)
        return try XCTUnwrap(maybe)
    }

    private func newTask(
        _ key: String,
        source: TaskSource = .icloud,
        subscriptionID: Int64? = nil,
        title: String? = nil
    ) -> NewTask {
        NewTask(
            rawURL: "https://www.bilibili.com/video/\(key)",
            taskKey: key,
            source: source,
            subscriptionID: subscriptionID,
            title: title
        )
    }

    func testAddRejectsDuplicateKey() async throws {
        let first = try await store.add(newTask("BV1GJ411x7h7"))
        let second = try await store.add(newTask("BV1GJ411x7h7"))
        XCTAssertNotNil(first)
        XCTAssertNil(second)

        let stats = try await store.stats()
        XCTAssertEqual(stats[.pending], 1)
        let keys = try await store.knownKeys()
        XCTAssertEqual(keys, ["BV1GJ411x7h7"])
    }

    func testAddBatchCountsOnlyNew() async throws {
        let tasks = [newTask("BV1"), newTask("BV2"), newTask("BV1")]
        let firstPass = try await store.addBatch(tasks)
        let secondPass = try await store.addBatch(tasks)
        XCTAssertEqual(firstPass, 2)
        XCTAssertEqual(secondPass, 0)
    }

    func testClaimOrdersByIdAndIncrementsAttempts() async throws {
        for key in ["BV1", "BV2", "BV3"] { try await store.add(newTask(key)) }

        let first = try await store.claim(limit: 2)
        XCTAssertEqual(first.map(\.taskKey), ["BV1", "BV2"])
        XCTAssertEqual(first.map(\.attempts), [1, 1])
        XCTAssertEqual(first.map(\.state), [.downloading, .downloading])

        let second = try await store.claim(limit: 10)
        XCTAssertEqual(second.map(\.taskKey), ["BV3"])

        let third = try await store.claim(limit: 10)
        XCTAssertEqual(third.count, 0)
    }

    func testClaimReturnsIncrementedAttemptsSoRetryBudgetIsCorrect() async throws {
        try await store.add(newTask("BV1"))
        // 三次 claim 应看到 attempts 1 / 2 / 3，正好对应「第三次失败即放弃」。
        for expected in 1...3 {
            let claimed = try await store.claim(limit: 1)
            let attempts = claimed.first?.attempts
            XCTAssertEqual(attempts, expected)
            let id = try XCTUnwrap(claimed.first?.id)
            try await store.finish(id: id, state: .failed, error: "boom")
            try await store.retryLater(id: id, error: "boom")
        }
    }

    func testFinishPersistsMultipleOutputs() async throws {
        let id = try await addTask("BV1")
        try await store.finish(id: id, state: .done, outputs: [
            TaskOutput(path: "/d/UP/a - 01.mp4", bytes: 10),
            TaskOutput(path: "/d/UP/a - 02.mp4", bytes: 20),
        ], backend: "yutto")
        let task = try await loadTask(id)
        XCTAssertEqual(task.state, .done)
        XCTAssertEqual(task.backend, "yutto")
        XCTAssertEqual(task.outputs.map(\.path), ["/d/UP/a - 01.mp4", "/d/UP/a - 02.mp4"])
        XCTAssertEqual(task.outputs.map(\.bytes), [10, 20])
    }

    func testFinishReplacesPreviousOutputs() async throws {
        let id = try await addTask("BV1")
        try await store.finish(id: id, state: .done, outputs: [TaskOutput(path: "/d/old.mp4")])
        try await store.finish(id: id, state: .done, outputs: [TaskOutput(path: "/d/new.mp4")])
        let task = try await loadTask(id)
        XCTAssertEqual(task.outputs.map(\.path), ["/d/new.mp4"])
    }

    func testFinishKeepsExistingTitleWhenNewIsEmpty() async throws {
        let id = try await addTask("BV1", title: "原标题")
        try await store.finish(id: id, state: .done, title: "")
        var task = try await loadTask(id)
        XCTAssertEqual(task.title, "原标题")

        try await store.finish(id: id, state: .done, title: "新标题")
        task = try await loadTask(id)
        XCTAssertEqual(task.title, "新标题")
    }

    func testMetadataRoundTrip() async throws {
        let id = try await addTask("BV1")
        try await store.setMetadata(
            id: id, bvid: "BV1", title: "标题", ownerName: "UP", ownerMid: 42,
            duration: 300, pageCount: 3
        )
        let task = try await loadTask(id)
        XCTAssertEqual(task.bvid, "BV1")
        XCTAssertEqual(task.title, "标题")
        XCTAssertEqual(task.ownerName, "UP")
        XCTAssertEqual(task.ownerMid, 42)
        XCTAssertEqual(task.duration, 300)
        XCTAssertEqual(task.pageCount, 3)
    }

    func testRecoverInterruptedMovesDownloadingBackToPending() async throws {
        try await store.addBatch([newTask("BV1"), newTask("BV2")])
        _ = try await store.claim(limit: 2)
        let before = try await store.stats()
        XCTAssertEqual(before[.downloading], 2)

        let recovered = try await store.recoverInterrupted()
        XCTAssertEqual(recovered, 2)
        let after = try await store.stats()
        XCTAssertEqual(after[.pending], 2)
        XCTAssertEqual(after[.downloading], 0)

        let again = try await store.recoverInterrupted()
        XCTAssertEqual(again, 0)
    }

    func testRequeueResetsAttemptsAndError() async throws {
        let id = try await addTask("BV1")
        _ = try await store.claim(limit: 1)
        try await store.finish(id: id, state: .failed, error: "坏了")
        var task = try await loadTask(id)
        XCTAssertEqual(task.attempts, 1)

        try await store.requeue(id: id)
        task = try await loadTask(id)
        XCTAssertEqual(task.state, .pending)
        XCTAssertEqual(task.attempts, 0)
        XCTAssertNil(task.error)
    }

    func testDeleteRefusesDownloadingTask() async throws {
        let id = try await addTask("BV1")
        _ = try await store.claim(limit: 1)
        try await store.delete(id: id)
        let stillThere = try await store.task(id: id)
        XCTAssertNotNil(stillThere, "下载中的任务不该被删掉")

        try await store.retryLater(id: id, error: "x")
        try await store.delete(id: id)
        let gone = try await store.task(id: id)
        XCTAssertNil(gone)
    }

    func testStatsCountsAllStates() async throws {
        try await store.addBatch([newTask("BV1"), newTask("BV2"), newTask("BV3")])
        _ = try await store.claim(limit: 1)
        let stats = try await store.stats()
        XCTAssertEqual(stats[.pending], 2)
        XCTAssertEqual(stats[.downloading], 1)
        XCTAssertEqual(stats[.done], 0)
        XCTAssertEqual(stats[.failed], 0)
    }

    func testTasksByStateAndSubscriptionCount() async throws {
        try await store.addBatch([
            newTask("BV1", source: .subscription, subscriptionID: 7),
            newTask("BV2", source: .subscription, subscriptionID: 7),
            newTask("BV3", source: .manual),
        ])
        let pending = try await store.tasks(in: [.pending], limit: 10)
        let done = try await store.tasks(in: [.done], limit: 10)
        let captured = try await store.countForSubscription(7)
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(done.count, 0)
        XCTAssertEqual(captured, 2)
    }

    func testRecentIsNewestFirst() async throws {
        for key in ["BV1", "BV2", "BV3"] { try await store.add(newTask(key)) }
        let recent = try await store.recent(limit: 2)
        XCTAssertEqual(recent.map(\.taskKey), ["BV3", "BV2"])
    }

    func testPersistsAcrossReopen() async throws {
        try await store.add(newTask("BV1", title: "留存"))
        let reopened = try TaskStore(path: path)
        let keys = try await reopened.knownKeys()
        let newest = try await reopened.recent(limit: 1)
        XCTAssertEqual(keys, ["BV1"])
        XCTAssertEqual(newest.first?.title, "留存")
    }

    func testMigrationIsIdempotent() throws {
        let db = try SQLiteDatabase(path: path)
        XCTAssertEqual(db.userVersion, 1)
        try Schema.migrate(db)
        try Schema.migrate(db)
        XCTAssertEqual(db.userVersion, 1)
        // AUTOINCREMENT 会额外建 sqlite_sequence，不算业务表。
        let tables = try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        ).compactMap { $0.text("name") }
        XCTAssertEqual(tables, ["meta", "subscriptions", "task_outputs", "tasks"])
    }

    func testDatesAndOptionalsRoundTrip() async throws {
        let pubdate = Date(timeIntervalSince1970: 1_700_000_000)
        let task = NewTask(
            rawURL: "u", taskKey: "BV9", source: .clipboard,
            bvid: "BV9", title: "t", ownerName: "o", ownerMid: 5,
            pubdate: pubdate, duration: 123, pageCount: 2
        )
        let maybeID = try await store.add(task)
        let id = try XCTUnwrap(maybeID)
        let stored = try await loadTask(id)
        XCTAssertEqual(stored.source, .clipboard)
        XCTAssertEqual(stored.pubdate, pubdate)
        XCTAssertEqual(stored.duration, 123)
        XCTAssertEqual(stored.pageCount, 2)
        XCTAssertEqual(stored.ownerMid, 5)
    }

    func testNilOptionalsStayNil() async throws {
        let id = try await addTask("BV1")
        let stored = try await loadTask(id)
        XCTAssertNil(stored.title)
        XCTAssertNil(stored.bvid)
        XCTAssertNil(stored.pubdate)
        XCTAssertNil(stored.duration)
        XCTAssertEqual(stored.source, .icloud)
    }
}

final class LegacyReaderTests: XCTestCase {
    private var directory: String!
    private var path: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "liuying-legacy-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = (directory as NSString).appendingPathComponent("state.db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    /// 造一个旧版 Python 的 schema，字段与其 CREATE TABLE 一致。
    private func makeLegacyDatabase() throws {
        let db = try SQLiteDatabase(path: path)
        try db.exec("""
        CREATE TABLE tasks (
            id INTEGER PRIMARY KEY,
            raw_url TEXT NOT NULL,
            task_key TEXT NOT NULL UNIQUE,
            bvid TEXT, title TEXT,
            state TEXT NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0,
            backend TEXT, error TEXT, out_path TEXT,
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        """)
        let now = Date().timeIntervalSince1970
        for (key, url, state) in [
            ("BV1GJ411x7h7", "https://www.bilibili.com/video/BV1GJ411x7h7", "done"),
            ("BV1p8nh61Efm", "https://b23.tv/abc123", "done"),
            ("BV1NxdGBJEWa", "https://b23.tv/def456", "failed"),
        ] {
            try db.run(
                "INSERT INTO tasks (raw_url, task_key, state, created_at, updated_at) VALUES (?,?,?,?,?);",
                [.text(url), .text(key), .text(state), .double(now), .double(now)]
            )
        }
    }

    func testReadsOnlyDoneTasks() throws {
        try makeLegacyDatabase()
        let tasks = LegacyReader.completedTasks(databasePath: path)
        XCTAssertEqual(tasks.map(\.taskKey).sorted(), ["BV1GJ411x7h7", "BV1p8nh61Efm"])
    }

    func testCompletedKeysIncludeRawURL() throws {
        try makeLegacyDatabase()
        let keys = LegacyReader.completedKeys(databasePath: path)
        XCTAssertTrue(keys.contains("BV1GJ411x7h7"))
        XCTAssertTrue(keys.contains("https://b23.tv/abc123"))
        XCTAssertFalse(keys.contains("BV1NxdGBJEWa"), "failed 的不算已完成")
    }

    func testMissingDatabaseReturnsEmpty() {
        XCTAssertEqual(LegacyReader.completedTasks(databasePath: path + ".nope"), [])
        XCTAssertEqual(LegacyReader.completedKeys(databasePath: path + ".nope"), [])
    }

    func testDatabaseWithoutTasksTableReturnsEmpty() throws {
        let db = try SQLiteDatabase(path: path)
        try db.exec("CREATE TABLE other (x TEXT);")
        XCTAssertEqual(LegacyReader.completedTasks(databasePath: path), [])
    }
}