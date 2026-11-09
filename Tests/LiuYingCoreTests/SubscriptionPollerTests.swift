import XCTest
@testable import LiuYingCore

/// 用 URLProtocol 拦截真实 BiliClient 的请求，从而在不联网的情况下测轮询语义。
final class FakeBiliServer: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
    }

    /// (status, json) —— 由测试设置。
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: (@Sendable (URL) -> Reply)?

    static func setResponder(_ responder: @escaping @Sendable (URL) -> Reply) {
        lock.lock(); self.responder = responder; lock.unlock()
    }

    static func reset() {
        lock.lock(); responder = nil; lock.unlock()
    }

    static func json(_ object: Any, status: Int = 200) -> Reply {
        Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeBiliServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        FakeBiliServer.lock.lock()
        let responder = FakeBiliServer.responder
        FakeBiliServer.lock.unlock()

        guard let url = request.url, let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let reply = responder(url)
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SubscriptionPollerTests: XCTestCase {
    private var directory: String!
    private var taskStore: TaskStore!
    private var subStore: SubscriptionStore!
    private var poller: SubscriptionPoller!

    private let mid: Int64 = 486906719

    override func setUp() async throws {
        directory = NSTemporaryDirectory() + "liuying-sub-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: (directory as NSString).appendingPathComponent("state.db"))
        taskStore = try TaskStore(database: db)
        subStore = SubscriptionStore(database: db)
        let client = BiliClient(sessdata: nil, session: FakeBiliServer.makeSession())
        poller = SubscriptionPoller(store: subStore, taskStore: taskStore, client: client)
    }

    override func tearDown() async throws {
        FakeBiliServer.reset()
        taskStore = nil
        subStore = nil
        poller = nil
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// XCTUnwrap 是 @autoclosure，不能在里面 await。
    private func loadSubscription(_ id: Int64) async throws -> Subscription {
        let value = try await subStore.subscription(id: id)
        return try XCTUnwrap(value)
    }

    private func addSubscription() async throws -> Int64 {
        let id = try await subStore.add(mid: mid, name: nil)
        return try XCTUnwrap(id)
    }

    // MARK: - 假响应

    private func installServer(videos: [(bvid: String, title: String, created: Int)]) {
        let vlist: [[String: Any]] = videos.map { video in
            [
                "bvid": video.bvid,
                "aid": 1,
                "title": video.title,
                "pic": "https://i0.hdslb.com/x.jpg",
                "length": "01:00",
                "created": video.created,
            ]
        }
        // 闭包必须 @Sendable，所以把响应体全部预先编码成 Data。
        let navBody = Self.encode([
            "code": 0,
            "data": ["wbi_img": [
                "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png",
            ]],
        ])
        let arcBody = Self.encode([
            "code": 0,
            "data": [
                "list": ["vlist": vlist],
                "page": ["count": vlist.count, "pn": 1, "ps": 49],
            ],
        ])
        let firstBVID = videos.first?.bvid ?? "BV1"
        let firstTitle = videos.first?.title ?? ""
        let mid = self.mid
        let viewBody = Self.encode([
            "code": 0,
            "data": [
                "bvid": firstBVID,
                "title": firstTitle,
                "owner": ["mid": mid, "name": "测试UP"],
                "pages": [["page": 1, "cid": 1, "part": "P1", "duration": 60]],
            ],
        ])
        let notFound = Self.encode(["code": -404, "message": "unknown"])

        FakeBiliServer.setResponder { url in
            switch url.path {
            case "/x/web-interface/nav": FakeBiliServer.Reply(status: 200, body: navBody)
            case "/x/space/wbi/arc/search": FakeBiliServer.Reply(status: 200, body: arcBody)
            case "/x/web-interface/view": FakeBiliServer.Reply(status: 200, body: viewBody)
            default: FakeBiliServer.Reply(status: 404, body: notFound)
            }
        }
    }

    private static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func installBan() {
        FakeBiliServer.setResponder { _ in
            FakeBiliServer.json(["code": -412, "message": "request was banned"], status: 412)
        }
    }

    // MARK: - 首次同步

    func testFirstSyncRecordsWatermarkWithoutEnqueueingHistory() async throws {
        installServer(videos: [
            ("BV1new", "最新一条", 1_760_000_000),
            ("BV1old", "旧的一条", 1_750_000_000),
        ])
        let id = try await addSubscription()

        let outcome = await poller.pollNow(subscriptionID: id)
        XCTAssertEqual(outcome.added, 0, "首次同步不能把历史投稿灌进队列")
        XCTAssertTrue(outcome.initialSync)

        let keys = try await taskStore.knownKeys()
        XCTAssertTrue(keys.isEmpty)

        let subscription = try await loadSubscription(id)
        XCTAssertTrue(subscription.initialSyncDone)
        XCTAssertEqual(subscription.watermark, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(subscription.name, "测试UP")
        XCTAssertEqual(subscription.consecutiveErrors, 0)
    }

    // MARK: - 增量

    func testSecondSyncEnqueuesOnlyNewerVideos() async throws {
        let id = try await addSubscription()
        installServer(videos: [("BV1old", "旧", 1_750_000_000)])
        _ = await poller.pollNow(subscriptionID: id)

        installServer(videos: [
            ("BV1new", "新", 1_760_000_000),
            ("BV1old", "旧", 1_750_000_000),
        ])
        let outcome = await poller.pollNow(subscriptionID: id)
        XCTAssertEqual(outcome.added, 1)

        let keys = try await taskStore.knownKeys()
        XCTAssertEqual(keys, ["BV1new"])
        let recent = try await taskStore.recent(limit: 1)
        let task = try XCTUnwrap(recent.first)
        XCTAssertEqual(task.source, .subscription)
        XCTAssertEqual(task.subscriptionID, id)
        XCTAssertEqual(task.title, "新")
    }

    func testRepeatedPollDoesNotDuplicate() async throws {
        let id = try await addSubscription()
        installServer(videos: [("BV1a", "A", 1_750_000_000)])
        _ = await poller.pollNow(subscriptionID: id)

        installServer(videos: [
            ("BV1b", "B", 1_760_000_000),
            ("BV1a", "A", 1_750_000_000),
        ])
        _ = await poller.pollNow(subscriptionID: id)
        let second = await poller.pollNow(subscriptionID: id)
        XCTAssertEqual(second.added, 0)
        let keys = try await taskStore.knownKeys()
        XCTAssertEqual(keys.count, 1)
    }

    func testImportRecentEnqueuesRequestedCount() async throws {
        let id = try await addSubscription()
        installServer(videos: [
            ("BV1a", "A", 1_760_000_000),
            ("BV1b", "B", 1_759_000_000),
            ("BV1c", "C", 1_758_000_000),
        ])
        let added = await poller.importRecent(subscriptionID: id, count: 2)
        XCTAssertEqual(added, 2)
        let keys = try await taskStore.knownKeys()
        XCTAssertEqual(keys, ["BV1a", "BV1b"])
    }

    // MARK: - 熔断

    func testThreeConsecutiveFailuresDisableSubscription() async throws {
        let id = try await addSubscription()
        installBan()

        for _ in 0..<2 {
            _ = await poller.pollNow(subscriptionID: id)
            var subscription = try await loadSubscription(id)
            XCTAssertTrue(subscription.enabled, "前两次失败不该停用")
            XCTAssertGreaterThan(subscription.consecutiveErrors, 0)
        }

        _ = await poller.pollNow(subscriptionID: id)
        let disabled = try await loadSubscription(id)
        XCTAssertFalse(disabled.enabled, "连续三次失败应自动停用")
        XCTAssertNotNil(disabled.disabledReason)
    }

    func testSuccessResetsErrorCounter() async throws {
        let id = try await addSubscription()
        installBan()
        _ = await poller.pollNow(subscriptionID: id)
        var subscription = try await loadSubscription(id)
        XCTAssertEqual(subscription.consecutiveErrors, 1)

        installServer(videos: [("BV1a", "A", 1_760_000_000)])
        _ = await poller.pollNow(subscriptionID: id)
        subscription = try await loadSubscription(id)
        XCTAssertEqual(subscription.consecutiveErrors, 0)
        XCTAssertNil(subscription.disabledReason)
    }

    func testDisabledSubscriptionIsSkippedByPollAll() async throws {
        let id = try await addSubscription()
        try await subStore.setEnabled(id: id, enabled: false)
        installServer(videos: [("BV1a", "A", 1_760_000_000)])
        let added = await poller.pollAll()
        XCTAssertEqual(added, 0)
    }

    func testAddRejectsDuplicateMid() async throws {
        let first = try await subStore.add(mid: mid, name: nil)
        let second = try await subStore.add(mid: mid, name: nil)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }
}