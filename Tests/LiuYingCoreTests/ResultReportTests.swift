import XCTest
@testable import LiuYingCore

/// P1 契约：`--result-json` / `--progress-json` 的 argv 形态与解析。
final class BiliDlResultContractsTests: XCTestCase {
    private let url = "https://www.bilibili.com/video/BV1GJ411x7h7"

    func testResultJSONUsesEqualsForm() {
        // 必须用等号形式：单 token，老版本 liuying-engine 不认识该 flag 时整条忽略，
        // 不会把路径泄漏成第二个位置参数（否则会多下一个不存在的 URL）。
        let args = BiliDlArgs.build(
            config: BiliDlConfig(), url: url, downloadDir: "/d",
            binaryPath: "liuying-engine",
            resultPath: "/support/work/task-7/result.json",
            emitProgressJSON: true
        )
        XCTAssertTrue(args.contains("--result-json=/support/work/task-7/result.json"))
        XCTAssertFalse(args.contains("--result-json"), "不能用空格分隔形式")
        XCTAssertTrue(args.contains("--progress-json"))
        // 路径不能被当成位置参数。
        XCTAssertEqual(args.filter { $0 == "/support/work/task-7/result.json" }.count, 0)
    }

    func testNoResultFlagsWhenNotRequested() {
        let args = BiliDlArgs.build(config: BiliDlConfig(), url: url, downloadDir: "/d", binaryPath: "liuying-engine")
        XCTAssertFalse(args.contains("--progress-json"))
        XCTAssertFalse(args.contains { $0.hasPrefix("--result-json") })
    }

    func testEmptyResultPathIsOmitted() {
        let args = BiliDlArgs.build(
            config: BiliDlConfig(), url: url, downloadDir: "/d",
            binaryPath: "liuying-engine", resultPath: ""
        )
        XCTAssertFalse(args.contains { $0.hasPrefix("--result-json") })
    }
}

final class BiliDlEventParsingTests: XCTestCase {
    func testParsesProgressEvent() throws {
        let line = #"{"event":"progress","media_id":"BV1","bv":"BV1","page":1,"kind":"video","current":50,"total":100,"percent":50,"speed_bps":1024,"ts":1}"#
        let event = try XCTUnwrap(BiliDlEvent.parse(line: line))
        XCTAssertEqual(event.event, "progress")
        XCTAssertEqual(event.mediaID, "BV1")
        XCTAssertEqual(event.kind, "video")
        XCTAssertEqual(event.percent, 50)
        XCTAssertEqual(event.progress.current, 50)
        XCTAssertEqual(event.progress.speedBPS, 1024)
    }

    func testNonJSONLinesReturnNil() {
        // 普通日志行必须原样落到日志里，不能被误吞。
        XCTAssertNil(BiliDlEvent.parse(line: "下载路径: /tmp/x"))
        XCTAssertNil(BiliDlEvent.parse(line: "{"))
        XCTAssertNil(BiliDlEvent.parse(line: "not json"))
        XCTAssertNil(BiliDlEvent.parse(line: #"{"broken":"#))
    }

    func testUnknownFieldsAreIgnored() throws {
        // Go 侧新增字段不能让旧客户端解析失败。
        let line = #"{"event":"done","bv":"BV1","message":"a.mp4","future_field":{"x":1}}"#
        let event = try XCTUnwrap(BiliDlEvent.parse(line: line))
        XCTAssertEqual(event.event, "done")
        XCTAssertEqual(event.message, "a.mp4")
    }

    func testDoneEventCarriesOutputs() throws {
        let line = #"{"event":"done","bv":"BV1","kind":"video","outputs":[{"path":"/d/a.mkv","kind":"video","container":"mkv","bytes":42}],"ts":1}"#
        let event = try XCTUnwrap(BiliDlEvent.parse(line: line))
        let outputs = try XCTUnwrap(event.outputs)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].path, "/d/a.mkv")
        XCTAssertEqual(outputs[0].container, "mkv")
        XCTAssertEqual(outputs[0].bytes, 42)
    }
}

final class BiliDlReportTests: XCTestCase {
    private func write(_ json: String) -> String {
        let path = NSTemporaryDirectory() + "liuying-report-\(UUID().uuidString).json"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testLoadsSucceededReport() throws {
        let path = write(#"""
        {
          "version": "1",
          "generated_at": "2026-11-25T21:15:03+08:00",
          "state": "succeeded",
          "outputs": [{"path":"/d/UP/a.mkv","kind":"video","container":"mkv","bytes":100}],
          "targets": [{"media_id":"BV1","bv":"BV1","page":1,"title":"t","state":"succeeded"}]
        }
        """#)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let report = try XCTUnwrap(BiliDlReport.load(path: path))
        XCTAssertEqual(report.version, "1")
        XCTAssertEqual(report.state, "succeeded")
        XCTAssertEqual(report.outputs.count, 1)
        XCTAssertEqual(report.outputs[0].path, "/d/UP/a.mkv")
        XCTAssertEqual(report.targets.first?.bv, "BV1")
        XCTAssertNil(report.failureSummary)
    }

    func testPartialReportSummarizesFailures() throws {
        let path = write(#"""
        {"version":"1","state":"partial","outputs":[],
         "targets":[
           {"bv":"BV1","state":"succeeded"},
           {"bv":"BV2","state":"failed","error":"HTTP 503"},
           {"bv":"BV3","state":"failed","error":"需要登录"}
         ]}
        """#)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let report = try XCTUnwrap(BiliDlReport.load(path: path))
        XCTAssertEqual(report.state, "partial")
        let summary = try XCTUnwrap(report.failureSummary)
        XCTAssertTrue(summary.contains("2 个目标失败"), summary)
        XCTAssertTrue(summary.contains("HTTP 503"))
    }

    func testMissingOutputsKeyDecodesAsEmpty() throws {
        // 旧版/异常情况下可能没有 outputs，不能让解码整体失败。
        let path = write(#"{"version":"1","state":"failed","targets":[]}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let report = try XCTUnwrap(BiliDlReport.load(path: path))
        XCTAssertTrue(report.outputs.isEmpty)
        XCTAssertEqual(report.state, "failed")
    }

    func testMissingFileReturnsNil() {
        // 返回 nil 是「这批二进制不支持 --result-json」的信号，调用方据此回退差集。
        XCTAssertNil(BiliDlReport.load(path: "/nonexistent/result.json"))
    }

    func testCorruptFileReturnsNil() {
        let path = write("{not json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(BiliDlReport.load(path: path))
    }
}

final class ProgressBoxTests: XCTestCase {
    func testKeepsLatest() {
        let box = ProgressBox()
        XCTAssertNil(box.latest)
        box.update(DownloadProgress(kind: "video", percent: 10))
        box.update(DownloadProgress(kind: "audio", percent: 55))
        XCTAssertEqual(box.latest?.percent, 55)
        XCTAssertEqual(box.latest?.kind, "audio")
        box.clear()
        XCTAssertNil(box.latest)
    }

    func testConcurrentUpdatesDoNotCrash() {
        let box = ProgressBox()
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            for sub in 0..<20 {
                box.update(DownloadProgress(kind: "video", percent: Double(index * 20 + sub)))
            }
            _ = box.latest
        }
        XCTAssertNotNil(box.latest)
    }

    func testDisplayText() {
        let progress = DownloadProgress(kind: "video", current: 50, total: 100, percent: 50, speedBPS: 1024 * 1024)
        let text = progress.displayText
        XCTAssertTrue(text.contains("视频流"), text)
        XCTAssertTrue(text.contains("50%"), text)
        XCTAssertTrue(text.contains("/s"), text)

        // 进度未知时只回类型名，不编造数字。
        XCTAssertEqual(DownloadProgress(kind: "audio").displayText, "音频流")
        XCTAssertEqual(DownloadProgress().displayText, "")
    }
}

final class BackendOutputFilterTests: XCTestCase {
    func testStripsNDJSONFromErrorSummary() {
        // 开 --progress-json 后 stdout 混着事件行，错误提示里不能出现原始 JSON。
        let raw = """
        {"event":"start","bv":"BV1","kind":"video","message":"a.mkv","ts":1}
        下载失败 (1/3): HTTP 503
        {"event":"error","bv":"BV1","kind":"video","message":"HTTP 503","ts":2}
        完成，1 个任务失败
        """
        let clean = BiliDlBackend.humanReadable(raw)
        XCTAssertFalse(clean.contains("\"event\""), clean)
        XCTAssertTrue(clean.contains("HTTP 503"), clean)
        XCTAssertTrue(clean.contains("完成，1 个任务失败"), clean)
    }

    func testHumanReadableOnPlainLog() {
        let raw = "\n下载路径: /tmp/x\n解析视频 BV1\n"
        XCTAssertEqual(BiliDlBackend.humanReadable(raw), "下载路径: /tmp/x\n解析视频 BV1")
    }

    func testHumanReadableOnEmptyInput() {
        XCTAssertEqual(BiliDlBackend.humanReadable(""), "")
        XCTAssertEqual(BiliDlBackend.humanReadable("\n\n"), "")
    }
}
