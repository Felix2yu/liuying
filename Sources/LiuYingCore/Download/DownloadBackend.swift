import Foundation

public struct DownloadResult: Sendable {
    public var success: Bool
    public var outputs: [TaskOutput]
    public var errorMessage: String?
    public var cancelled: Bool
    /// 后端原始输出（已截断），失败时用于诊断。
    public var logTail: [String]
    /// 是否真的确认了产出文件，从而允许把链接从 links.txt 删掉。
    /// Downie 是异步入队、liuying-engine 退出 0 但零产出都不能删——否则链接丢了就再也找不回来。
    public var safeToPrune: Bool
    /// 已交给外部应用（Downie），完成与否只能由用户确认，任务进 .sent 而非 .done。
    public var handedOff: Bool

    public init(
        success: Bool, outputs: [TaskOutput] = [], errorMessage: String? = nil,
        cancelled: Bool = false, logTail: [String] = [], safeToPrune: Bool = false,
        handedOff: Bool = false
    ) {
        self.success = success
        self.outputs = outputs
        self.errorMessage = errorMessage
        self.cancelled = cancelled
        self.logTail = logTail
        self.safeToPrune = safeToPrune
        self.handedOff = handedOff
    }
}

public protocol DownloadBackend: Sendable {
    var name: String { get }
    func download(
        url: String,
        workDir: String,
        handle: ProcessHandle,
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async -> DownloadResult
}

extension DownloadBackend {
    /// 不关心进度的后端（Downie 是异步入队，拿不到百分比）走这个重载。
    public func download(
        url: String,
        workDir: String,
        handle: ProcessHandle,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> DownloadResult {
        await download(url: url, workDir: workDir, handle: handle, onLine: onLine, onProgress: { _ in })
    }
}

/// liuying-engine 后端（内嵌 Go CLI，兼容 yutto argv）。参数构造在 `BiliDlArgs`（纯函数），
/// 这里负责快照、执行、零产出判定与容器规整。
public struct BiliDlBackend: DownloadBackend {
    public let name = "liuying-engine"
    private let config: BiliDlConfig
    private let downloadDir: String
    private let timeout: TimeInterval

    public init(config: BiliDlConfig, downloadDir: String, timeout: TimeInterval) {
        self.config = config
        self.downloadDir = downloadDir
        self.timeout = timeout
    }

    public func download(
        url: String,
        workDir: String,
        handle: ProcessHandle,
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async -> DownloadResult {
        guard let binary = resolveBinary() else {
            return DownloadResult(
                success: false,
                errorMessage: "找不到 liuying-engine 可执行文件：\(config.binary)。请确认 .app 内嵌完整，或在设置里指定绝对路径。"
            )
        }

        // 结果文件放在每任务独立的 workDir 里：并发任务不会互相覆盖，
        // workDir 在任务结束后由引擎删除，残留也无害。
        let resultPath = (workDir as NSString).appendingPathComponent("result.json")
        try? FileManager.default.removeItem(atPath: resultPath)

        let authExists = AuthFile.exists(path: config.authFile)
        let args = BiliDlArgs.build(
            config: config,
            url: url,
            downloadDir: downloadDir,
            workDir: workDir,
            authFileExists: authExists,
            binaryPath: binary,
            resultPath: resultPath,
            emitProgressJSON: true
        )
        Log.info("liuying-engine 开始下载：\(url)")
        Log.debug("命令：\(args.joined(separator: " "))")

        let tail = LogTail()
        let result = await Subprocess.run(
            executable: binary,
            arguments: Array(args.dropFirst()),
            environment: Subprocess.environment(),
            // CWD 设为 workDir：与 yutto 时代的约定保持一致（旧版会读 ./yutto.toml）；
            // liuying-engine 的产物一律落在 -d，不读 CWD 配置，但保留此约定便于排查。
            currentDirectory: workDir,
            timeout: timeout,
            handle: handle,
            onOutputLine: { line in
                if let event = BiliDlEvent.parse(line: line) {
                    // 机器可读事件：转成进度 + 人读日志，不把原始 JSON 灌进 UI。
                    Self.handle(event: event, tail: tail, onLine: onLine, onProgress: onProgress)
                    return
                }
                tail.append(line)
                onLine(line)
            }
        )

        if result.cancelled {
            return DownloadResult(success: false, errorMessage: "已取消", cancelled: true, logTail: tail.snapshot)
        }
        if !result.launched {
            return DownloadResult(success: false, errorMessage: result.stderr, logTail: tail.snapshot)
        }
        if result.timedOut {
            return DownloadResult(
                success: false,
                errorMessage: "liuying-engine 执行超时（\(Int(timeout))s）",
                logTail: tail.snapshot
            )
        }

        // 只认结构化结果：留影与引擎同仓演进、一起打包，不存在「旧引擎」这种情况。
        // 读不到 result.json 说明打包不完整或引擎被换掉了，直接失败比猜更有用。
        guard let report = BiliDlReport.load(path: resultPath) else {
            return DownloadResult(
                success: false,
                errorMessage: "liuying-engine 没有产出 result.json（退出码 \(result.exitCode)）。"
                    + "引擎与客户端需要一起打包，请重新构建 .app。日志：\n"
                    + String(Self.humanReadable(result.stdout + result.stderr).suffix(600)),
                logTail: tail.snapshot
            )
        }
        return await finishFromReport(
            report, exitCode: result.exitCode,
            stdout: result.stdout + result.stderr, tail: tail.snapshot
        )
    }

    /// 从进程输出里剔掉 NDJSON 事件行，只留人读文本。
    ///
    /// 开启 --progress-json 后 stdout 混着事件行，直接塞进错误提示会变成
    /// 一长串 `{"event":"start",…}`，对用户毫无意义。
    static func humanReadable(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { BiliDlEvent.parse(line: String($0)) == nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把一条 NDJSON 事件转成人读日志与进度。
    /// progress 事件频率高（数百毫秒一次），只喂进度、不进日志，否则日志会被刷屏。
    static func handle(
        event: BiliDlEvent,
        tail: LogTail,
        onLine: @Sendable (String) -> Void,
        onProgress: @Sendable (DownloadProgress) -> Void
    ) {
        switch event.event {
        case "progress":
            onProgress(event.progress)
        case "done":
            onProgress(event.progress)
            emit(event, prefix: "完成", tail: tail, onLine: onLine)
        case "error":
            emit(event, prefix: "失败", tail: tail, onLine: onLine)
        default: // start 及未来新增的事件类型
            emit(event, prefix: "开始", tail: tail, onLine: onLine)
        }
    }

    private static func emit(
        _ event: BiliDlEvent,
        prefix: String,
        tail: LogTail,
        onLine: @Sendable (String) -> Void
    ) {
        let label = DownloadProgress(kind: event.kind ?? "").displayText
        let lead = label.isEmpty ? "" : label + " "
        let text = lead + prefix + "：" + (event.message ?? "")
        tail.append(text)
        onLine(text)
    }

    /// 按 result.json 的终态构造结果。
    private func finishFromReport(
        _ report: BiliDlReport,
        exitCode: Int32,
        stdout: String,
        tail: [String]
    ) async -> DownloadResult {
        switch report.state {
        case "succeeded":
            let outputs = await finalize(raw: report.outputs)
            guard !outputs.isEmpty else {
                // 报告成功但清单为空，说明结果文件与产物不一致，宁可当失败重试也不要静默成功。
                return DownloadResult(
                    success: false,
                    errorMessage: "liuying-engine 报告成功但产物清单为空，无法确认下载结果",
                    logTail: tail
                )
            }
            Log.success("liuying-engine 下载完成：\(outputs.count) 个文件")
            return DownloadResult(success: true, outputs: outputs, logTail: tail, safeToPrune: true)

        case "canceled":
            return DownloadResult(success: false, errorMessage: "已取消", cancelled: true, logTail: tail)

        case "partial":
            let done = report.targets.filter { $0.state == "succeeded" }.count
            let total = max(report.targets.count, done)
            return DownloadResult(
                success: false,
                errorMessage: "部分内容下载失败（成功 \(done)/\(total)）："
                    + (report.failureSummary ?? "未知原因"),
                logTail: tail
            )

        default: // failed / 未知状态
            let human = Self.humanReadable(stdout)
            let summary = report.failureSummary
                ?? (human.isEmpty ? "下载失败（liuying-engine 未给出原因）" : String(human.suffix(500)))
            return DownloadResult(
                success: false,
                errorMessage: "liuying-engine 退出码 \(exitCode)：\(summary)",
                logTail: tail
            )
        }
    }

    /// 把产物规整到目标容器，并按真实文件大小回报。
    ///
    /// 只对媒体文件做 remux：封面/弹幕/字幕交给容器策略没有意义，
    /// 反而可能被 ffmpeg 改坏。
    private func finalize(raw: [BiliDlOutput]) async -> [TaskOutput] {
        let ffprobe = Subprocess.lookupOnPATH("ffprobe")
        let ffmpeg = Subprocess.lookupOnPATH("ffmpeg")
        var outputs: [TaskOutput] = []
        for item in raw {
            var path = item.path
            if item.kind == "video" || item.kind == "audio" {
                path = await ContainerFinalizer.finalize(
                    path: path, policy: config.outputContainers,
                    ffprobePath: ffprobe, ffmpegPath: ffmpeg
                )
            }
            outputs.append(TaskOutput(path: path, kind: item.kind, bytes: Self.fileSize(path) ?? item.bytes))
        }
        return outputs
    }

    private func resolveBinary() -> String? {
        BundledTool.resolveBiliDl(configured: config.binary)
    }

    static func fileSize(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}

/// Downie 4 官方集成：`downie://XUOpenURL?url=…&postprocessing=…&destination=…`。
/// GUI 应用，脚本侧无法判定完成：入队成功后任务落「已交给 Downie」(.sent)，
/// 由用户在队列里确认完成。旧版直接记 done 并把链接删掉，没下成时无从恢复。
public struct DownieBackend: DownloadBackend {
    public let name = "downie"
    private let config: DownieConfig
    private let downloadDir: String

    public init(config: DownieConfig, downloadDir: String) {
        self.config = config
        self.downloadDir = downloadDir
    }

    public func download(
        url: String,
        workDir: String,
        handle: ProcessHandle,
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async -> DownloadResult {
        // Downie 是异步入队，脚本侧拿不到百分比，onProgress 永不触发。
        guard let appPath = Self.resolveAppPath(configured: config.appName) else {
            return DownloadResult(
                success: false,
                errorMessage: "找不到「\(config.appName)」。请在「设置 → Downie → 应用名」里填应用名"
                    + "（如 Downie 4）或 .app 的绝对路径。"
            )
        }
        let scheme = Self.schemeURL(config: config, url: url, downloadDir: downloadDir)

        Log.info("交给 Downie：\(url)")
        onLine("open -a \"\(appPath)\" \"\(scheme)\"")
        let result = await Subprocess.run(
            executable: "/usr/bin/open",
            // 用解析后的**绝对路径**而不是应用名：`open -a <名字>` 要过 LaunchServices 的名字
            // 解析，失败时只会吐一句 `-600 procNotFound`，排不出是名字写错还是 LS 没索引。
            arguments: ["-a", appPath, scheme],
            environment: Subprocess.environment(),
            timeout: 30,
            handle: handle
        )
        if result.cancelled {
            return DownloadResult(success: false, errorMessage: "已取消", cancelled: true)
        }
        guard result.launched, result.exitCode == 0 else {
            return DownloadResult(
                success: false,
                errorMessage: "调用 Downie 失败：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        // Downie 是异步的，这里只能确认「已入队」。任务落 .sent，由用户在队列里确认完成；
        // 确认前不删 links.txt，也不算进「已完成」。
        return DownloadResult(
            success: true,
            outputs: [TaskOutput(
                path: Self.destinationDirectory(config: config, downloadDir: downloadDir),
                kind: "downie"
            )],
            logTail: ["已交给 Downie，下载进度请在 Downie 里查看"],
            handedOff: true
        )
    }

    static func destinationDirectory(config: DownieConfig, downloadDir: String) -> String {
        config.destination.isEmpty ? downloadDir : AppIdentity.expand(config.destination)
    }

    /// 把配置里的「应用名」解析成 .app 的绝对路径。
    /// 支持三种写法：`Downie 4`、`Downie 4.app`、`/Applications/Downie 4.app`。
    public static func resolveAppPath(configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = AppIdentity.expand(trimmed)
        if expanded.contains("/") || expanded.hasSuffix(".app") {
            return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
        }
        let candidates = [
            "/Applications/\(trimmed).app",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/\(trimmed).app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// 构造 `downie://XUOpenURL?...`。与 download() 共用，便于只做预览而不真的调用。
    public static func schemeURL(config: DownieConfig, url: String, downloadDir: String) -> String {
        var params: [(String, String)] = [("url", url)]
        if !config.postprocessing.isEmpty {
            params.append(("postprocessing", config.postprocessing))
        }
        let destination = destinationDirectory(config: config, downloadDir: downloadDir)
        if !destination.isEmpty {
            params.append(("destination", destination))
        }
        let query = params
            .map { "\(percentEscape($0.0))=\(percentEscape($0.1))" }
            .joined(separator: "&")
        return "downie://XUOpenURL?" + query
    }

    /// 等价 Python 的 `urlencode(..., quote_via=quote)`：空格→%20（不是 +），保留 `/`。
    /// 注意与 WBI 的 form-escape 不同，不能复用。
    static func percentEscape(_ raw: String) -> String {
        var out = ""
        for byte in raw.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E, 0x2F:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }
}