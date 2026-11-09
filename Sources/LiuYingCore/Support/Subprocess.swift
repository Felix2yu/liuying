//  统一子进程封装，移植自 ntfyx/Sources/NtfyxCore/ScriptRunner.swift 的 Subprocess 部分。
//  相对原版的三处改动：
//   1. enhancedPATH 补 ~/.local/bin（yutto 是 uv tool 装在那里的，GUI 应用继承的 PATH 没有它）
//   2. 支持指定 currentDirectoryURL（yutto 会读 ./yutto.toml，CWD 必须刻意控制）
//   3. 新增按行流式回调，供队列行展开时看实时日志；以及 ProcessHandle 支持从 UI 取消

import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    /// false 表示根本没启动起来（文件不存在、不可执行……）。
    public var launched: Bool
    /// 被 ProcessHandle.cancel() 主动终止。
    public var cancelled: Bool

    public init(
        exitCode: Int32, stdout: String, stderr: String,
        timedOut: Bool, launched: Bool, cancelled: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.launched = launched
        self.cancelled = cancelled
    }
}

/// 交给调用方持有，用于「取消当前下载」。attach 之前 cancel 也生效。
public final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let killNow = cancelled
        lock.unlock()
        if killNow { terminate(p) }
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    public var pid: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    public var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p { terminate(p) }
    }

    private var currentProcess: Process? {
        lock.lock(); defer { lock.unlock() }
        return process
    }

    /// SIGTERM，宽限期后仍在跑就 SIGKILL。
    private func terminate(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Subprocess.killGracePeriod) { [weak self] in
            guard let self, let proc = self.currentProcess, proc.isRunning else { return }
            kill(proc.processIdentifier, SIGKILL)
        }
    }
}

public enum Subprocess {
    public static let defaultTimeout: TimeInterval = 120
    public static let killGracePeriod: TimeInterval = 5

    /// GUI 应用继承的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin。
    /// yutto 依赖 ffmpeg 合并音视频，缺了直接失败；yutto 自身又装在 ~/.local/bin。
    public static let enhancedPATH: String = {
        let localBin = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
        return "\(localBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    public static func environment(extra: [String: String]? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // 先设死：调用方的 extra 不允许覆盖 PATH。
        env["PATH"] = enhancedPATH
        for key in ["NO_PROXY", "no_proxy"] {
            if let value = env[key] { env[key] = sanitizedNoProxy(value) }
        }
        if let extra {
            for (key, value) in extra where key != "PATH" { env[key] = value }
        }
        return env
    }

    /// yutto 用的 httpx 会把 NO_PROXY 的每一项当 URL 解析，遇到 `[::1]` 这种带方括号的
    /// IPv6 写法会抛 `InvalidURL: Invalid port: ':1]'` 让整个下载失败（本机 shell 的
    /// NO_PROXY 恰好含 `[::1]`）。GUI 应用从 launchd 继承不到这个变量，但命令行工具会。
    static func sanitizedNoProxy(_ value: String) -> String {
        value
            .split(separator: ",")
            .filter { !$0.contains("[") && !$0.contains("]") }
            .joined(separator: ",")
    }

    /// 把裸命令名解析成绝对路径。Process 自己不做 PATH 查找。
    public static func lookupOnPATH(_ name: String) -> String? {
        if name.contains("/") {
            let expanded = AppIdentity.expand(name)
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let callerPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = enhancedPATH.split(separator: ":").map(String.init)
            + callerPATH.split(separator: ":").map(String.init)
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// - Parameters:
    ///   - onOutputLine: 每收到一整行（stdout 与 stderr 合流）调用一次，**在后台私有队列上**，
    ///     必须是非阻塞的 @Sendable 闭包。行尾不含换行符；EOF 时残留的无换行尾段也会补发一次。
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        handle: ProcessHandle? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    currentDirectory: currentDirectory,
                    timeout: timeout,
                    handle: handle,
                    onOutputLine: onOutputLine
                ))
            }
        }
    }

    public static func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        handle: ProcessHandle? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }

        let box = OutputBox(onLine: onOutputLine)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let eofGroup = DispatchGroup()
        eofGroup.enter()
        eofGroup.enter()
        installReader(on: stdoutPipe.fileHandleForReading, into: box, group: eofGroup, isStderr: false)
        installReader(on: stderrPipe.fileHandleForReading, into: box, group: eofGroup, isStderr: true)

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(
                exitCode: -1, stdout: "",
                stderr: "无法执行 \(executable)：\(error.localizedDescription)",
                timedOut: false, launched: false
            )
        }

        handle?.attach(process)
        let watchdog = Watchdog(process: process, timeout: timeout)
        watchdog.start()
        process.waitUntilExit()
        watchdog.cancel()
        handle?.detach()

        // EOF 回调在后台队列投递，收尾时补 drain 一次。
        _ = eofGroup.wait(timeout: .now() + 2)
        box.flush()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: box.stdout,
            stderr: box.stderr,
            timedOut: watchdog.didTimeOut,
            launched: true,
            cancelled: handle?.wasCancelled ?? false
        )
    }

    private static func installReader(
        on handle: FileHandle,
        into box: OutputBox,
        group: DispatchGroup,
        isStderr: Bool
    ) {
        handle.readabilityHandler = { readHandle in
            let data = readHandle.availableData
            if data.isEmpty {
                readHandle.readabilityHandler = nil
                group.leave()
            } else {
                box.append(data, isStderr: isStderr)
            }
        }
    }

    /// 带行切分的输出累积器。readabilityHandler 在私有队列上触发，全程持锁。
    /// stdout/stderr 分别累积，但行回调合流（按到达先后），因为日志尾不需要区分来源。
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var pending = Data()
        private let onLine: (@Sendable (String) -> Void)?

        init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

        func append(_ chunk: Data, isStderr: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isStderr { err.append(chunk) } else { out.append(chunk) }
            guard let onLine else { return }
            pending.append(chunk)
            while let idx = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<idx]
                pending.removeSubrange(pending.startIndex...idx)
                onLine(String(decoding: lineData, as: UTF8.self))
            }
        }

        /// EOF 后补发没有换行符的尾段。
        func flush() {
            lock.lock()
            defer { lock.unlock() }
            guard let onLine, !pending.isEmpty else { return }
            onLine(String(decoding: pending, as: UTF8.self))
            pending = Data()
        }

        var stdout: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: out, as: UTF8.self)
        }

        var stderr: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: err, as: UTF8.self)
        }
    }

    /// 死线到点 SIGTERM，宽限期后仍存活则 SIGKILL。
    private final class Watchdog: @unchecked Sendable {
        private unowned let process: Process
        private let queue = DispatchQueue(label: "im.yufei.liuying.subprocess.watchdog")
        private let timeout: TimeInterval
        private var armed = true
        private let timedOutLock = NSLock()
        private var timedOut = false

        init(process: Process, timeout: TimeInterval) {
            self.process = process
            self.timeout = timeout
        }

        func start() {
            guard timeout.isFinite, timeout > 0 else { return }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.fire() }
        }

        private func fire() {
            guard armed else { return }
            guard process.isRunning else { return }
            timedOutLock.lock()
            timedOut = true
            timedOutLock.unlock()
            process.terminate()
            queue.asyncAfter(deadline: .now() + Subprocess.killGracePeriod) { [weak self] in
                guard let self, self.armed, self.process.isRunning else { return }
                kill(self.process.processIdentifier, SIGKILL)
            }
        }

        func cancel() {
            // 与 fire 同一队列：在死线工作项之前入队的 cancel 保证先执行。
            queue.async { self.armed = false }
        }

        var didTimeOut: Bool {
            timedOutLock.lock(); defer { timedOutLock.unlock() }
            return timedOut
        }
    }
}