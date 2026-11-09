import Foundation

public struct DownloadResult: Sendable {
    public var success: Bool
    public var outputs: [TaskOutput]
    public var errorMessage: String?
    public var cancelled: Bool
    /// 后端原始输出（已截断），失败时用于诊断。
    public var logTail: [String]

    public init(
        success: Bool, outputs: [TaskOutput] = [], errorMessage: String? = nil,
        cancelled: Bool = false, logTail: [String] = []
    ) {
        self.success = success
        self.outputs = outputs
        self.errorMessage = errorMessage
        self.cancelled = cancelled
        self.logTail = logTail
    }
}

public protocol DownloadBackend: Sendable {
    var name: String { get }
    func download(
        url: String,
        workDir: String,
        handle: ProcessHandle,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> DownloadResult
}

/// yutto 后端。参数构造在 `YuttoArgs`（纯函数），这里负责快照、执行与容器规整。
public struct YuttoBackend: DownloadBackend {
    public let name = "yutto"
    private let config: YuttoConfig
    private let downloadDir: String
    private let timeout: TimeInterval

    public init(config: YuttoConfig, downloadDir: String, timeout: TimeInterval) {
        self.config = config
        self.downloadDir = downloadDir
        self.timeout = timeout
    }

    public func download(
        url: String,
        workDir: String,
        handle: ProcessHandle,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> DownloadResult {
        guard let binary = resolveBinary() else {
            return DownloadResult(
                success: false,
                errorMessage: "找不到 yutto 可执行文件：\(config.binary)。请在设置里指定绝对路径。"
            )
        }

        let authExists = AuthFile.exists(path: config.authFile)
        let args = YuttoArgs.build(
            config: config,
            url: url,
            downloadDir: downloadDir,
            workDir: workDir,
            authFileExists: authExists,
            binaryPath: binary
        )
        Log.info("yutto 开始下载：\(url)")
        Log.debug("命令：\(args.joined(separator: " "))")

        let before: FileSnapshot
        guard let captured = await FileSnapshot.capture(root: downloadDir) else {
            return DownloadResult(
                success: false,
                errorMessage: "无法读取下载目录（可能缺少文件访问权限）：\(downloadDir)"
            )
        }
        before = captured
        let tail = LogTail()
        let result = await Subprocess.run(
            executable: binary,
            arguments: Array(args.dropFirst()),
            environment: Subprocess.environment(),
            // CWD 必须是 workDir：yutto 会读 ./yutto.toml，落在下载目录里会静默覆盖参数。
            currentDirectory: workDir,
            timeout: timeout,
            handle: handle,
            onOutputLine: { line in
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
                errorMessage: "yutto 执行超时（\(Int(timeout))s）",
                logTail: tail.snapshot
            )
        }
        guard result.exitCode == 0 else {
            let output = (result.stdout + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = String(output.suffix(800))
            return DownloadResult(
                success: false,
                errorMessage: "yutto 退出码 \(result.exitCode)：\(summary)",
                logTail: tail.snapshot
            )
        }

        guard let after = await FileSnapshot.capture(root: downloadDir) else {
            return DownloadResult(
                success: false,
                errorMessage: "下载结束后无法读取下载目录（可能缺少文件访问权限），无法确认产出文件"
            )
        }
        let newFiles = after.newFiles(comparedTo: before)
        if newFiles.isEmpty {
            // 视频已存在时 yutto 会跳过且返回 0。旧版同样按成功处理。
            Log.warning("yutto 成功但未发现新文件（可能已存在）：\(url)")
            return DownloadResult(success: true, outputs: [], logTail: tail.snapshot)
        }

        let ffprobe = Subprocess.lookupOnPATH("ffprobe")
        let ffmpeg = Subprocess.lookupOnPATH("ffmpeg")
        var outputs: [TaskOutput] = []
        for file in newFiles {
            let finalPath = await ContainerFinalizer.finalize(
                path: file, policy: config.outputContainers,
                ffprobePath: ffprobe, ffmpegPath: ffmpeg
            )
            let bytes = Self.fileSize(finalPath)
            outputs.append(TaskOutput(path: finalPath, kind: "video", bytes: bytes))
        }
        Log.success("yutto 下载完成：\(outputs.count) 个文件")
        return DownloadResult(success: true, outputs: outputs, logTail: tail.snapshot)
    }

    private func resolveBinary() -> String? {
        let configured = config.binary.trimmingCharacters(in: .whitespaces)
        guard !configured.isEmpty else { return nil }
        return Subprocess.lookupOnPATH(configured)
    }

    static func fileSize(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}

/// Downie 4 官方集成：`downie://XUOpenURL?url=…&postprocessing=…&destination=…`。
/// GUI 应用，脚本侧无法判定完成，**入队即视为成功**（与旧版一致）。
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
        onLine: @escaping @Sendable (String) -> Void
    ) async -> DownloadResult {
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
        // Downie 是异步的，这里只能确认「已入队」。
        return DownloadResult(
            success: true,
            outputs: [TaskOutput(
                path: Self.destinationDirectory(config: config, downloadDir: downloadDir),
                kind: "downie"
            )],
            logTail: ["已交给 Downie，下载进度请在 Downie 里查看"]
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