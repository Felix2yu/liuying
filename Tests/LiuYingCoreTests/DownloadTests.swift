import XCTest
@testable import LiuYingCore

final class LogTailTests: XCTestCase {
    func testKeepsOnlyLastLines() {
        let tail = LogTail(limit: 3)
        for index in 1...10 { tail.append("line \(index)") }
        XCTAssertEqual(tail.snapshot, ["line 8", "line 9", "line 10"])
    }

    func testConcurrentAppendsDoNotCrash() {
        let tail = LogTail(limit: 1000)
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            for sub in 0..<20 { tail.append("\(index)-\(sub)") }
        }
        XCTAssertEqual(tail.snapshot.count, 1000)
    }

    func testClearEmpties() {
        let tail = LogTail()
        tail.append("x")
        tail.clear()
        XCTAssertTrue(tail.snapshot.isEmpty)
    }
}

final class DownieURLTests: XCTestCase {
    func testPercentEscapeMatchesPythonQuote() {
        // Python 的 quote()：空格→%20、保留 /、转义 & 与中文。
        XCTAssertEqual(DownieBackend.percentEscape("a b"), "a%20b")
        XCTAssertEqual(DownieBackend.percentEscape("/a/b"), "/a/b")
        XCTAssertEqual(DownieBackend.percentEscape("a&b=c"), "a%26b%3Dc")
        XCTAssertEqual(DownieBackend.percentEscape("中"), "%E4%B8%AD")
        XCTAssertEqual(DownieBackend.percentEscape("av1,hevc"), "av1%2Chevc")
        XCTAssertEqual(DownieBackend.percentEscape("-_.~"), "-_.~")
    }
}
final class DownieAppResolutionTests: XCTestCase {
    private var root: String!

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "liuying-downie-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root + "/Fake.app", withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    func testResolvesAbsoluteAppPath() {
        let path = root + "/Fake.app"
        XCTAssertEqual(DownieBackend.resolveAppPath(configured: path), path)
    }

    func testMissingAbsolutePathReturnsNil() {
        XCTAssertNil(DownieBackend.resolveAppPath(configured: root + "/Nope.app"))
        XCTAssertNil(DownieBackend.resolveAppPath(configured: ""))
        XCTAssertNil(DownieBackend.resolveAppPath(configured: "   "))
    }

    /// 按名字解析依赖本机是否装了 Downie，只断言「解析出来的路径必须真实存在」。
    func testNameResolutionOnlyReturnsExistingBundles() {
        if let resolved = DownieBackend.resolveAppPath(configured: "Downie 4") {
            XCTAssertTrue(resolved.hasSuffix("Downie 4.app"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved))
        }
    }
}
