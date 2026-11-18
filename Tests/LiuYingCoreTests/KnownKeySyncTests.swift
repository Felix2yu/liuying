import XCTest
@testable import LiuYingCore

// MARK: - 清单编解码与并集（纯逻辑）

final class KnownKeySyncLogicTests: XCTestCase {
    func testDecodeSkipsCommentsBlankAndWhitespace() {
        let text = """
        # 流影去重键清单
        BV1GJ411x7h7

          BV1xx411c7mD
        #p2 这行是注释吗？不是，以 # 开头一律跳过
        """
        let keys = KnownKeySync.decode(text)
        XCTAssertEqual(keys, ["BV1GJ411x7h7", "BV1xx411c7mD"])
    }

    func testDecodeKeepsURLWithHashFragment() {
        // 键以 http 开头，中间的 # 不能当注释切掉。
        let url = "https://example.com/v/1#p2"
        let keys = KnownKeySync.decode("# header\n\(url)\n")
        XCTAssertTrue(keys.contains(url))
    }

    func testEncodeIsStableAndHeaderIsIgnoredOnDecode() {
        let a = KnownKeySync.encode(keys: ["BV2", "BV1"])
        let b = KnownKeySync.encode(keys: ["BV1", "BV2"])
        XCTAssertEqual(a, b, "排序必须稳定，否则每次写都产生 diff")
        XCTAssertTrue(a.hasSuffix("\n"), "尾部换行，避免追加时粘行")
        XCTAssertEqual(KnownKeySync.decode(a), ["BV1", "BV2"])
    }

    func testMergeIsUnionNeverDropsExisting() {
        let merged = KnownKeySync.merge(
            existing: ["A", "B", "C"],
            adding: ["C", "D"]
        )
        XCTAssertEqual(merged, ["A", "B", "C", "D"])
        XCTAssertTrue(KnownKeySync.merge(existing: ["A"], adding: []).contains("A"))
    }

    func testManifestPathSitsBesideLinkFile() {
        let path = KnownKeySync.manifestPath(
            forLinkFile: "/tmp/iCloud/Documents/Bili/links.txt"
        )
        XCTAssertEqual(path, "/tmp/iCloud/Documents/Bili/liuying-known-keys.txt")
    }
}

// MARK: - 清单 IO

final class KnownKeySyncIOTests: XCTestCase {
    private var directory: String!
    private var path: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "liuying-keysync-\(UUID().uuidString)"
        path = (directory as NSString).appendingPathComponent(KnownKeySync.fileName)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    func testReadMissingReturnsMissing() async {
        let result = await KnownKeySync.read(path: path!)
        XCTAssertEqual(result, .missing)
    }

    func testAddKeysCreatesThenAppendsWithoutLosingOldOnes() async {
        let first = await KnownKeySync.addKeys(["BV1", "BV2"], to: path!)
        XCTAssertEqual(first, .written(count: 2))

        let afterFirst = await KnownKeySync.read(path: path!)
        XCTAssertEqual(afterFirst, .keys(["BV1", "BV2"]))

        // 追加只带一个新键，旧键必须还在（这正是两台 Mac 并发写不丢键的机制）。
        let second = await KnownKeySync.addKeys(["BV3"], to: path!)
        XCTAssertEqual(second, .written(count: 3))

        let afterSecond = await KnownKeySync.read(path: path!)
        XCTAssertEqual(afterSecond, .keys(["BV1", "BV2", "BV3"]))
    }

    func testAddKeysWithDuplicateInputIsIdempotent() async {
        _ = await KnownKeySync.addKeys(["BV1"], to: path!)
        let again = await KnownKeySync.addKeys(["BV1", "BV1"], to: path!)
        XCTAssertEqual(again, .written(count: 1))
        let result = await KnownKeySync.read(path: path!)
        XCTAssertEqual(result, .keys(["BV1"]))
    }

    func testAddEmptyIsNoOp() async {
        let added = await KnownKeySync.addKeys([], to: path!)
        XCTAssertEqual(added, .written(count: 0))
        // 空集合不应凭空创建文件。
        let result = await KnownKeySync.read(path: path!)
        XCTAssertEqual(result, .missing)
    }
}

// MARK: - TaskStore 导入

final class TaskStoreDedupSyncTests: XCTestCase {
    private var directory: String!
    private var store: TaskStore!

    override func setUp() async throws {
        directory = NSTemporaryDirectory() + "liuying-dedup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        store = try TaskStore(
            path: (directory as NSString).appendingPathComponent("state.db")
        )
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: directory)
        try await super.tearDown()
    }

    func testImportKnownKeysAreDedupOnlyNoTasks() async throws {
        let added = try await store.importKnownKeys(["BV1GJ411x7h7", "https://example.com/v/2"])
        XCTAssertEqual(added, 2)

        // 只占去重键，不建任务 → 队列里不会冒出几百条空记录。
        let stats = try await store.stats()
        XCTAssertEqual(stats.values.reduce(0, +), 0)
        let claimed = try await store.claim(limit: 10)
        XCTAssertTrue(claimed.isEmpty)
        let synced = try await store.syncedKeyCount()
        XCTAssertEqual(synced, 2)

        let keys = try await store.knownKeys()
        XCTAssertEqual(keys, ["BV1GJ411x7h7", "https://example.com/v/2"])
    }

    func testImportIsIdempotentAndSkipsExistingTaskKeys() async throws {
        _ = try await store.add(NewTask(
            rawURL: "https://www.bilibili.com/video/BV1GJ411x7h7",
            taskKey: "BV1GJ411x7h7", source: .icloud
        ))
        // 一条已在任务表，一条重复，一条全新。
        let added = try await store.importKnownKeys(["BV1GJ411x7h7", "BVNEW", "BVNEW"])
        XCTAssertEqual(added, 1)
        let synced = try await store.syncedKeyCount()
        XCTAssertEqual(synced, 1)
        let keys = try await store.knownKeys()
        XCTAssertEqual(keys, ["BV1GJ411x7h7", "BVNEW"])
    }

    func testImportedKeyParticipatesInDedup() async throws {
        _ = try await store.importKnownKeys(["BV1GJ411x7h7"])
        // 去重发生在引擎 enqueue 层（拿 knownKeys() 判定），store.add 自身只按 tasks 表查重。
        // 这里验证导入的键确实进了去重全集，引擎级行为见 EngineDedupSyncTests。
        let keys = try await store.knownKeys()
        XCTAssertTrue(keys.contains("BV1GJ411x7h7"))
    }
}

// MARK: - 引擎新机场景

final class EngineDedupSyncTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "liuying-engine-sync-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    /// 复现用户场景：旧机的清单里有已下过的键，新机空库 + links.txt 残留旧行 + 新增一行。
    /// 只有新增那行应该入队，旧行被清单导入的键挡住。
    func testFreshMachineDoesNotRedownloadManifestKeys() async throws {
        let linkFile = (directory as NSString).appendingPathComponent("links.txt")
        // 必须用合法的 10 位 BV 号，否则 KeyResolver 会把键退化成完整 URL。
        let oldKey = "BV1GJ411x7h7"
        let newKey = "BV1xx411c7mD"
        try "https://www.bilibili.com/video/\(oldKey)\nhttps://www.bilibili.com/video/\(newKey)\n"
            .write(toFile: linkFile, atomically: true, encoding: .utf8)
        let manifest = KnownKeySync.manifestPath(forLinkFile: linkFile)
        _ = await KnownKeySync.addKeys([oldKey], to: manifest)

        var config = AppConfig()
        config.notify = false
        config.watchFile = linkFile          // 指定路径，跳过自动发现
        config.downloadDir = directory!
        let store = try TaskStore(path: (directory as NSString).appendingPathComponent("state.db"))
        let engine = Engine(store: store, config: config)

        // 跑一轮：collect → 导入清单 → 去重入队 → 下载。
        // 这里不关心下载结果（yutto 可能没装），只看入队去重是否正确。
        await engine.runOnce()

        let known = try await store.knownKeys()
        XCTAssertTrue(known.contains(oldKey), "旧键应从清单导入")
        XCTAssertTrue(known.contains(newKey), "新链接应入队")
        let synced = try await store.syncedKeyCount()
        XCTAssertEqual(synced, 1)

        let oldTask = try await store.tasks(in: [.pending, .downloading, .done, .failed])
            .first { $0.taskKey == oldKey }
        XCTAssertNil(oldTask, "旧链接不该建任务，否则就是全量重下")
    }

    /// 启动时 refreshLinkStatus() 与主循环并行，可能抢先入队。它也必须先在入队前导入清单。
    func testRefreshLinkStatusAlsoImportsBeforeEnqueue() async throws {
        let linkFile = (directory as NSString).appendingPathComponent("links.txt")
        let oldKey = "BV1GJ411x7h7"
        let newKey = "BV1xx411c7mD"
        try "https://www.bilibili.com/video/\(oldKey)\nhttps://www.bilibili.com/video/\(newKey)\n"
            .write(toFile: linkFile, atomically: true, encoding: .utf8)
        let manifest = KnownKeySync.manifestPath(forLinkFile: linkFile)
        _ = await KnownKeySync.addKeys([oldKey], to: manifest)

        var config = AppConfig()
        config.notify = false
        config.watchFile = linkFile
        config.downloadDir = directory!
        let store = try TaskStore(path: (directory as NSString).appendingPathComponent("state.db"))
        let engine = Engine(store: store, config: config)

        // 只调 refreshLinkStatus，不跑主循环——模拟它抢先的路径。
        await engine.refreshLinkStatus()

        let oldTask = try await store.tasks(in: [.pending, .downloading, .done, .failed])
            .first { $0.taskKey == oldKey }
        XCTAssertNil(oldTask, "refreshLinkStatus 抢先时也不能把旧键下成任务")
        let newTask = try await store.tasks(in: [.pending, .downloading, .done, .failed])
            .first { $0.taskKey == newKey }
        XCTAssertNotNil(newTask, "新链接仍应入队")
    }
}
