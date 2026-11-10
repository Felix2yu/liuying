import XCTest
@testable import LiuYingCore

final class FileSnapshotTests: XCTestCase {
    private var root: String!

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "liuying-snap-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    @discardableResult
    private func touch(_ relative: String) -> String {
        let path = (root as NSString).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        return path
    }

    /// XCTUnwrap 是 @autoclosure，不能在里面 await。
    private func snapshot(_ root: String) async throws -> FileSnapshot {
        let value = await FileSnapshot.capture(root: root)
        return try XCTUnwrap(value)
    }

    /// yutto 的多 P 产物必须**全部**进快照 —— 旧版只记 sorted(new)[-1] 一个文件，这是要修的 bug。
    func testCapturesAllMediaFilesIncludingMultiPart() async throws {
        touch("UP/a.mkv")
        touch("UP/a (1).mkv")
        touch("UP/a (2).mkv")
        let snapshot = try await snapshot(root)
        XCTAssertEqual(snapshot.files.count, 3)
    }

    func testIgnoresNonMediaAndHiddenFiles() async throws {
        touch("UP/a.mkv")
        touch("UP/cover.jpg")
        touch("UP/sub.ass")
        touch("UP/danmaku.xml")
        touch("UP/.DS_Store")
        let snapshot = try await snapshot(root)
        XCTAssertEqual(snapshot.files.map { ($0 as NSString).lastPathComponent }, ["a.mkv"])
    }

    func testNewFilesDiffIsSortedAndExcludesPreexisting() async throws {
        let existing = touch("UP/a.mkv")
        let before = try await snapshot(root)

        touch("UP/a (1).mkv")
        touch("UP/b.mp4")
        let after = try await snapshot(root)

        let new = after.newFiles(comparedTo: before)
        XCTAssertEqual(new.count, 2)
        XCTAssertFalse(new.contains(existing))
        XCTAssertEqual(new, new.sorted())
    }

    func testMissingDirectoryIsAFailureNotAnEmptySnapshot() async throws {
        let value = await FileSnapshot.capture(root: root + "/does-not-exist")
        XCTAssertNil(value, "目录不存在/不可读必须返回 nil，不能被当成「没有新文件」")
    }

    func testEmptyDiffWhenNothingChanged() async throws {
        touch("UP/a.mkv")
        let snapshot = try await snapshot(root)
        XCTAssertEqual(snapshot.newFiles(comparedTo: snapshot), [])
    }
}

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
