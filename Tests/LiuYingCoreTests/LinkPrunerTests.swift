import XCTest
@testable import LiuYingCore

final class LinkFilePrunerTests: XCTestCase {
    private var directory: String!
    private var file: String!
    private var backups: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "liuying-prune-\(UUID().uuidString)"
        backups = (directory as NSString).appendingPathComponent("backups")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        file = (directory as NSString).appendingPathComponent("links.txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
    }

    private func read() throws -> String {
        // 不能用 String(contentsOfFile:encoding:)：它会吞掉 BOM，让 BOM 断言永远失败。
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self)
    }

    func testRemovesConsumedLineAndKeepsOthersByteIdentical() async throws {
        let bv1 = "https://www.bilibili.com/video/BV1GJ411x7h7"
        let bv2 = "https://www.bilibili.com/video/BV1p8nh61Efm"
        let original = "第一行\n\(bv1)\n第三行：全角「测试」\n\(bv2)\n"
        try write(original)

        let result = await LinkFilePruner.apply(
            path: file, consumed: [bv1], backupDirectory: backups
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(try read(), "第一行\n第三行：全角「测试」\n\(bv2)\n")
        XCTAssertNotNil(result.backupPath)
        if let backupPath = result.backupPath {
            XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), original)
        }
    }

    func testNoMatchLeavesFileUntouched() async throws {
        let text = "https://www.bilibili.com/video/BV1GJ411x7h7\n"
        try write(text)
        let before = try FileManager.default.attributesOfItem(atPath: file)

        let result = await LinkFilePruner.apply(
            path: file, consumed: ["BV1p8nh61Efm"], backupDirectory: backups
        )
        XCTAssertFalse(result.applied)
        XCTAssertEqual(try read(), text)
        let after = try FileManager.default.attributesOfItem(atPath: file)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testEmptyConsumedIsNoop() async throws {
        try write("anything\n")
        let result = await LinkFilePruner.apply(path: file, consumed: [], backupDirectory: nil)
        XCTAssertFalse(result.applied)
        XCTAssertEqual(try read(), "anything\n")
    }

    func testMissingFileReportsReason() async {
        let result = await LinkFilePruner.apply(
            path: directory + "/nope.txt", consumed: ["BV1"], backupDirectory: nil
        )
        XCTAssertFalse(result.applied)
        XCTAssertNotNil(result.reason)
    }

    func testPreviewDoesNotModify() async throws {
        let text = "a\nhttps://www.bilibili.com/video/BV1GJ411x7h7\nb\n"
        try write(text)
        let preview = await LinkFilePruner.preview(path: file, consumed: ["BV1GJ411x7h7"])
        XCTAssertEqual(preview?.removedLines, 1)
        XCTAssertEqual(preview?.totalLines, 3)
        XCTAssertEqual(preview?.removedURLs, 1)
        XCTAssertEqual(try read(), text)
    }

    func testPreviewCountsProseLineAsModified() async throws {
        let text = "分享 https://b23.tv/abc 好看\n"
        try write(text)
        let preview = await LinkFilePruner.preview(path: file, consumed: ["https://b23.tv/abc"])
        XCTAssertEqual(preview?.removedLines, 0)
        XCTAssertEqual(preview?.modifiedLines, 1)
    }

    func testCRLFFileIsRewrittenWithCRLFPreserved() async throws {
        let text = "a\r\nhttps://www.bilibili.com/video/BV1GJ411x7h7\r\nb\r\n"
        try write(text)
        let result = await LinkFilePruner.apply(
            path: file, consumed: ["BV1GJ411x7h7"], backupDirectory: nil
        )
        XCTAssertTrue(result.applied)
        let after = try read()
        XCTAssertEqual(after, "a\r\nb\r\n")
        XCTAssertEqual(after.utf8.filter { $0 == 0x0D }.count, 2)
    }

    func testBOMIsPreserved() async throws {
        let text = "\u{FEFF}a\nhttps://www.bilibili.com/video/BV1GJ411x7h7\n"
        try write(text)
        _ = await LinkFilePruner.apply(path: file, consumed: ["BV1GJ411x7h7"], backupDirectory: nil)
        XCTAssertEqual(try read(), "\u{FEFF}a\n")
    }

    func testDuplicateURLsAllRemoved() async throws {
        let url = "https://www.bilibili.com/video/BV1GJ411x7h7"
        try write("\(url)\nkeep\n\(url)\n")
        let result = await LinkFilePruner.apply(path: file, consumed: [url], backupDirectory: nil)
        XCTAssertEqual(result.preview?.removedLines, 2)
        XCTAssertEqual(try read(), "keep\n")
    }

    func testTempFileIsCleanedUp() async throws {
        try write("https://www.bilibili.com/video/BV1GJ411x7h7\n")
        _ = await LinkFilePruner.apply(path: file, consumed: ["BV1GJ411x7h7"], backupDirectory: nil)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".links.txt.liuying-tmp") })
    }
}