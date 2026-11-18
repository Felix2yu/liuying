import AppKit
import XCTest
@testable import LiuYingCore

// MARK: - Downie 导出文件解析

final class DownieHistoryImporterTests: XCTestCase {
    private func parse(_ text: String, fileName: String = "") -> Result<DownieImportDocument, DownieImportError> {
        DownieHistoryImporter.parse(data: Data(text.utf8), fileName: fileName)
    }

    func testOfficialDownieXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <downloads>
          <download>
            <url>https://www.bilibili.com/video/BV1GJ411x7h7</url>
            <title>测试视频</title>
            <path>/Users/x/Downloads</path>
          </download>
          <download>
            <url>https://www.xiaohongshu.com/explore/abc</url>
            <title>另一条</title>
          </download>
        </downloads>
        """
        let doc = try XCTUnwrap(try parse(xml).get())
        XCTAssertEqual(doc.format, .xml)
        XCTAssertEqual(doc.records.count, 2)
        XCTAssertEqual(doc.records[0].url, "https://www.bilibili.com/video/BV1GJ411x7h7")
        XCTAssertEqual(doc.records[0].title, "测试视频")
        XCTAssertEqual(doc.records[0].filePath, "/Users/x/Downloads")
        XCTAssertEqual(doc.records[1].title, "另一条")
        XCTAssertEqual(doc.skipped, 0)
    }

    /// Downie 4 导出文件名/字段名与「导入格式」并不完全一致，按字段语义兼容。
    func testExportStyleXMLWithOriginalWebSiteURL() throws {
        let xml = """
        <history>
          <item>
            <originalWebSiteURLString>https://www.youtube.com/watch?v=abc</originalWebSiteURLString>
            <name>Clip</name>
            <date>2026-11-11 22:10</date>
          </item>
        </history>
        """
        let doc = try XCTUnwrap(try parse(xml).get())
        XCTAssertEqual(doc.records.count, 1)
        XCTAssertEqual(doc.records[0].url, "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(doc.records[0].title, "Clip")
    }

    func testXMLPlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <array>
          <dict>
            <key>url</key>
            <string>https://example.com/v/1</string>
            <key>title</key>
            <string>One</string>
          </dict>
        </array>
        </plist>
        """
        let doc = try XCTUnwrap(try parse(xml).get())
        XCTAssertEqual(doc.format, .plist)
        XCTAssertEqual(doc.records.count, 1)
        XCTAssertEqual(doc.records[0].url, "https://example.com/v/1")
        XCTAssertEqual(doc.records[0].title, "One")
    }

    func testCSVWithQuotedTitle() throws {
        let csv = """
        url,title,path
        https://www.bilibili.com/video/BV1GJ411x7h7,"标题, 带逗号",/tmp
        https://example.com/v/2,Second,
        """
        let doc = try XCTUnwrap(try parse(csv, fileName: "links.csv").get())
        XCTAssertEqual(doc.format, .csv)
        XCTAssertEqual(doc.records.count, 2)
        XCTAssertEqual(doc.records[0].title, "标题, 带逗号")
        XCTAssertEqual(doc.records[0].filePath, "/tmp")
        XCTAssertNil(doc.records[1].filePath)
    }

    func testPlainTextKeepsDuplicatesForReporting() throws {
        let text = """
        https://b23.tv/abc123
        https://b23.tv/abc123
        https://example.com/v/2
        """
        let doc = try XCTUnwrap(try parse(text).get())
        XCTAssertEqual(doc.format, .text)
        XCTAssertEqual(doc.records.map(\.url), [
            "https://b23.tv/abc123", "https://b23.tv/abc123", "https://example.com/v/2",
        ])
    }

    func testNonHTTPSchemesAreSkipped() throws {
        let xml = """
        <downloads>
          <download><url>ftp://example.com/a</url><title>不对</title></download>
          <download><url>https://example.com/v/2</url><title>对的</title></download>
        </downloads>
        """
        let doc = try XCTUnwrap(try parse(xml).get())
        XCTAssertEqual(doc.records.count, 1)
        XCTAssertEqual(doc.records[0].url, "https://example.com/v/2")
        XCTAssertEqual(doc.skipped, 1)
    }

    func testMalformedXMLIsReported() {
        guard case .failure(let error) = parse("<downloads><download><url>x</url>") else {
            return XCTFail("未闭合的 XML 应报解析错误")
        }
        guard case .malformedXML = error else {
            return XCTFail("错误类型应为 malformedXML，实际是 \(error)")
        }
    }

    func testUnrecognizedXMLRootIsFormatMismatch() {
        guard case .failure(let error) = parse("<config><url>https://example.com/a</url></config>") else {
            return XCTFail("无关 XML 应当拒绝")
        }
        XCTAssertEqual(error, .unrecognizedFormat)
    }

    func testJSONIsFormatMismatch() {
        guard case .failure(let error) = parse("{\"url\":\"https://example.com/a\"}") else {
            return XCTFail("JSON 不在支持范围内")
        }
        XCTAssertEqual(error, .unrecognizedFormat)
    }

    func testBinaryIsRejected() {
        let data = Data([0x00, 0x01, 0xFF, 0x02, 0x03])
        guard case .failure(let error) = DownieHistoryImporter.parse(data: data) else {
            return XCTFail("二进制文件应当拒绝")
        }
        XCTAssertEqual(error, .notText)
    }

    func testEmptyAndNoRecords() {
        XCTAssertEqual(DownieHistoryImporter.parse(data: Data()).failure, .emptyFile)
        guard case .failure(let error) = parse("这里只有文字，没有链接") else {
            return XCTFail("无链接文本应报 noRecords")
        }
        XCTAssertEqual(error, .noRecords)
    }

    func testTooLargeFileIsRejected() {
        let data = Data(repeating: 0x20, count: DownieHistoryImporter.maxFileBytes + 1)
        guard case .failure(let error) = DownieHistoryImporter.parse(data: data) else {
            return XCTFail("超大文件应当拒绝")
        }
        guard case .tooLarge = error else {
            return XCTFail("错误类型应为 tooLarge，实际是 \(error)")
        }
    }

    func testBOMIsTolerated() throws {
        let doc = try XCTUnwrap(try parse("\u{FEFF}https://example.com/v/1\n").get())
        XCTAssertEqual(doc.records.first?.url, "https://example.com/v/1")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - ⌘V 决策

final class PasteShortcutTests: XCTestCase {
    private let ok = (
        isEnabled: true, isAppActive: true, isMainWindowKey: true,
        hasSheet: false, isTextEditing: false
    )

    private func decide(_ clipboard: String?) -> PasteShortcut.Decision {
        PasteShortcut.evaluate(
            isEnabled: ok.isEnabled, isAppActive: ok.isAppActive,
            isMainWindowKey: ok.isMainWindowKey, hasSheet: ok.hasSheet,
            isTextEditing: ok.isTextEditing, clipboardText: clipboard
        )
    }

    func testDisabledOrInactiveAlwaysPassThrough() {
        XCTAssertEqual(
            PasteShortcut.evaluate(
                isEnabled: false, isAppActive: true, isMainWindowKey: true,
                hasSheet: false, isTextEditing: false, clipboardText: "https://b23.tv/a"
            ),
            .passthrough(.disabled)
        )
        XCTAssertEqual(
            PasteShortcut.evaluate(
                isEnabled: true, isAppActive: false, isMainWindowKey: true,
                hasSheet: false, isTextEditing: false, clipboardText: "https://b23.tv/a"
            ),
            .passthrough(.inactive)
        )
    }

    func testOrdinaryPasteContextsAreUntouched() {
        let cases: [(String, Bool, Bool, Bool, PasteShortcut.SkipReason)] = [
            ("窗口不对", false, false, false, .notMainWindow),
            ("有 sheet", true, true, false, .sheetPresent),
            ("输入框聚焦", true, false, true, .textEditing),
        ]
        for (label, main, sheet, editing, reason) in cases {
            XCTAssertEqual(
                PasteShortcut.evaluate(
                    isEnabled: true, isAppActive: true, isMainWindowKey: main,
                    hasSheet: sheet, isTextEditing: editing,
                    clipboardText: "https://b23.tv/a"
                ),
                .passthrough(reason),
                label
            )
        }
    }

    func testEmptyClipboardAndFormatMismatch() {
        XCTAssertEqual(decide(nil), .passthrough(.emptyClipboard))
        XCTAssertEqual(decide("   \n "), .passthrough(.emptyClipboard))
        XCTAssertEqual(decide("今天天气不错"), .passthrough(.noLinks))
        XCTAssertEqual(decide("ftp://example.com/a"), .passthrough(.noLinks))
    }

    func testTriggersOnShareText() {
        let text = "【一个视频】https://www.bilibili.com/video/BV1GJ411x7h7?vd_source=abc 快看"
        XCTAssertEqual(
            decide(text),
            .download(["https://www.bilibili.com/video/BV1GJ411x7h7?vd_source=abc"])
        )
    }

    func testTriggersOnMultipleDeduplicatedURLs() {
        let text = """
        https://b23.tv/a
        https://b23.tv/a
        https://example.com/v/2
        """
        XCTAssertEqual(decide(text), .download(["https://b23.tv/a", "https://example.com/v/2"]))
    }

    func testOnlyPlainCommandVIsIntercepted() {
        let command = NSEvent.ModifierFlags.command.rawValue
        XCTAssertTrue(PasteShortcut.isPlainCommandV(modifierFlags: command, characters: "v"))
        XCTAssertTrue(PasteShortcut.isPlainCommandV(modifierFlags: command, characters: "V"))
        XCTAssertTrue(PasteShortcut.isPlainCommandV(
            modifierFlags: command | NSEvent.ModifierFlags.capsLock.rawValue, characters: "v"
        ))
        XCTAssertFalse(PasteShortcut.isPlainCommandV(
            modifierFlags: command | NSEvent.ModifierFlags.shift.rawValue, characters: "v"
        ))
        XCTAssertFalse(PasteShortcut.isPlainCommandV(
            modifierFlags: command | NSEvent.ModifierFlags.option.rawValue, characters: "v"
        ))
        XCTAssertFalse(PasteShortcut.isPlainCommandV(
            modifierFlags: command | NSEvent.ModifierFlags.control.rawValue, characters: "v"
        ))
        XCTAssertFalse(PasteShortcut.isPlainCommandV(modifierFlags: command, characters: "c"))
        XCTAssertFalse(PasteShortcut.isPlainCommandV(
            modifierFlags: NSEvent.ModifierFlags.shift.rawValue, characters: "v"
        ))
    }

    func testNoticesOnlyForClipboardProblems() {
        XCTAssertNotNil(PasteShortcut.SkipReason.emptyClipboard.notice)
        XCTAssertNotNil(PasteShortcut.SkipReason.noLinks.notice)
        for reason in [PasteShortcut.SkipReason.disabled, .inactive, .notMainWindow, .sheetPresent, .textEditing] {
            XCTAssertNil(reason.notice, "\(reason) 不该打扰用户")
        }
    }
}

// MARK: - 配置与来源

final class DownieConfigTests: XCTestCase {
    func testPasteShortcutDefaultsToOnAndSurvivesRoundTrip() throws {
        var config = AppConfig()
        XCTAssertTrue(config.pasteShortcut)
        config.pasteShortcut = false
        config.clipboardMonitor = true
        let decoded = try AppConfig.decode(fromJSON: config.encodedJSON())
        XCTAssertFalse(decoded.pasteShortcut)
        XCTAssertTrue(decoded.clipboardMonitor)
    }

    func testMissingKeyFallsBackToDefault() throws {
        let json = #"{"poll_interval": 20}"#
        let config = try AppConfig.decode(fromJSON: Data(json.utf8))
        XCTAssertTrue(config.pasteShortcut)
        XCTAssertTrue(config.dedupSync, "旧配置缺键时去重同步默认开启")
    }

    func testDedupSyncSurvivesRoundTrip() throws {
        var config = AppConfig()
        XCTAssertTrue(config.dedupSync)
        config.dedupSync = false
        let decoded = try AppConfig.decode(fromJSON: config.encodedJSON())
        XCTAssertFalse(decoded.dedupSync)
    }

    func testDownieImportSource() {
        XCTAssertEqual(TaskSource.downieImport.rawValue, "downie_import")
        XCTAssertEqual(TaskSource.downieImport.displayName, "Downie 导入")
        XCTAssertNil(TaskSource(rawValue: "downie-import"))
    }
}

// MARK: - 引擎导入

final class DownieEngineImportTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "liuying-downie-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func fixture() async throws -> (Engine, TaskStore) {
        var config = AppConfig()
        config.notify = false
        let store = try TaskStore(
            path: (directory as NSString).appendingPathComponent("state.db")
        )
        return (Engine(store: store, config: config), store)
    }

    func testImportRegistersDoneRecordsWithoutDownloading() async throws {
        let (engine, store) = try await fixture()
        let first = DownieHistoryRecord(
            url: "https://www.bilibili.com/video/BV1GJ411x7h7",
            title: "来自 Downie"
        )
        let duplicateURL = DownieHistoryRecord(url: first.url, title: "重复")
        // 不同追踪参数 → 同一个 canonical key，也算文件内重复。
        let duplicateKey = DownieHistoryRecord(
            url: "https://www.bilibili.com/video/BV1GJ411x7h7?spm_id_from=333.999"
        )
        let other = DownieHistoryRecord(url: "https://example.com/v/2")

        let outcome = await engine.importDownieRecords([first, duplicateURL, duplicateKey, other])
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.scanned, 4)
        XCTAssertEqual(outcome.imported, 2)
        XCTAssertEqual(outcome.duplicatesInFile, 2)
        XCTAssertEqual(outcome.alreadyExists, 0)

        let tasks = try await store.tasks(in: [.done])
        XCTAssertEqual(tasks.count, 2)
        let bilibili = try XCTUnwrap(tasks.first { $0.rawURL == first.url })
        XCTAssertEqual(bilibili.state, .done)
        XCTAssertEqual(bilibili.source, .downieImport)
        XCTAssertEqual(bilibili.backend, "downie")
        XCTAssertEqual(bilibili.title, "来自 Downie")
        XCTAssertEqual(bilibili.taskKey, "BV1GJ411x7h7")
        XCTAssertEqual(bilibili.bvid, "BV1GJ411x7h7")
        XCTAssertEqual(bilibili.attempts, 0)
        XCTAssertTrue(bilibili.outputs.isEmpty, "导出文件里的路径不能伪装成本机产出")
        let claimed = try await store.claim(limit: 1)
        XCTAssertTrue(claimed.isEmpty, "归档记录不能触发下载")

        // 已归档的去重键会挡住之后重复粘贴同一链接。
        let again = await engine.addManual(text: first.url)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.duplicates, 1)
    }

    func testExistingTaskBlocksImportAndIsNotModified() async throws {
        let (engine, store) = try await fixture()
        let url = "https://example.com/v/1"
        let maybeExistingID = try await store.add(NewTask(
            rawURL: url, taskKey: url, source: .manual
        ))
        let existingID = try XCTUnwrap(maybeExistingID)

        let outcome = await engine.importDownieRecords([DownieHistoryRecord(url: url, title: "覆盖不了")])
        XCTAssertEqual(outcome.scanned, 1)
        XCTAssertEqual(outcome.imported, 0)
        XCTAssertEqual(outcome.alreadyExists, 1)

        let task = try await store.task(id: existingID)
        XCTAssertEqual(task?.state, .pending, "导入不能改写已有任务")
        XCTAssertEqual(task?.source, .manual)
        XCTAssertNil(task?.title)
    }

    func testReimportAndUndo() async throws {
        let (engine, store) = try await fixture()
        let records = [
            DownieHistoryRecord(url: "https://example.com/v/1"),
            DownieHistoryRecord(url: "https://example.com/v/2"),
        ]
        let first = await engine.importDownieRecords(records)
        XCTAssertEqual(first.imported, 2)

        // 重复导入同一份文件：全部按已有任务跳过。
        let second = await engine.importDownieRecords(records)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.alreadyExists, 2)

        // 同时放一条手动任务，撤销只能删导入的记录。
        let maybeManualID = try await store.add(NewTask(
            rawURL: "https://example.com/manual", taskKey: "manual-key", source: .manual
        ))
        let manualID = try XCTUnwrap(maybeManualID)
        let removed = await engine.undoImport(taskIDs: first.importedIDs + [manualID])
        XCTAssertEqual(removed, 2)
        let remainingDone = try await store.tasks(in: [.done])
        let manualTask = try await store.task(id: manualID)
        XCTAssertEqual(remainingDone.count, 0)
        XCTAssertNotNil(manualTask, "手动任务不能被撤销导入误删")
    }

    func testEmptyImportIsNoOp() async throws {
        let (engine, store) = try await fixture()
        let outcome = await engine.importDownieRecords([])
        XCTAssertEqual(outcome.scanned, 0)
        XCTAssertNil(outcome.failure)
        let keys = try await store.knownKeys()
        XCTAssertTrue(keys.isEmpty)
    }
}
