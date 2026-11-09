import Foundation
import OSLog

/// 双 sink 日志：os.Logger（Console.app / log stream 可见）+ 轮转文件（菜单「查看日志…」揭示）。
/// 移植自 ntfyx/Sources/NtfyxCore/Logger.swift。
public enum Log {
    private static let logger = Logger(
        subsystem: AppIdentity.effectiveBundleIdentifier,
        category: "app"
    )

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static var logFilePath: String {
        (AppIdentity.logDirectory as NSString).appendingPathComponent("liuying.log")
    }

    private static let maxLogSize: UInt64 = 1_000_000

    /// 跑单测时不写文件：测试会创建大量临时库并打日志，
    /// 混进 ~/Library/Logs/LiuYing/liuying.log 会污染真实运行记录（排查时极易误判）。
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// FileHandle 与 DateFormatter 都不是线程安全的；日志来自主线程、URLSession 回调队列和多个 actor。
    private static let writeLock = NSLock()
    private static let fileHandle: FileHandle? = setupLogFile()

    /// 调试日志开关。yutto 完整 argv 只在 debug 级别输出。
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var on: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
    private static let verboseFlag = Flag()
    public static var verbose: Bool {
        get { verboseFlag.on }
        set { verboseFlag.on = newValue }
    }

    private static func setupLogFile() -> FileHandle? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                atPath: AppIdentity.logDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("无法创建日志目录：\(error.localizedDescription, privacy: .public)")
            return nil
        }

        rotateLogIfNeeded()

        if !fileManager.fileExists(atPath: logFilePath) {
            fileManager.createFile(atPath: logFilePath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logFilePath) else {
            logger.error("无法打开日志文件写入")
            return nil
        }
        do {
            try handle.seekToEnd()
        } catch {
            logger.error("无法 seek 日志文件到末尾：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        return handle
    }

    private static func rotateLogIfNeeded() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: logFilePath),
              let attrs = try? fileManager.attributesOfItem(atPath: logFilePath),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        let oldLogPath = logFilePath + ".old"
        try? fileManager.removeItem(atPath: oldLogPath)
        try? fileManager.moveItem(atPath: logFilePath, toPath: oldLogPath)
    }

    private static func emit(level: OSLogType, _ message: String) {
        logger.log(level: level, "\(message, privacy: .public)")
        guard !isRunningTests else { return }

        writeLock.lock()
        defer { writeLock.unlock() }
        // DateFormatter 必须在锁内调用。
        let stamp = dateFormatter.string(from: Date())
        guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
        // 不逐行 fsync：日志不需要那种持久性，每行一次磁盘往返会拖住主线程。
        try? fileHandle?.write(contentsOf: data)
    }

    public static func debug(_ message: String) {
        guard verbose else { return }
        emit(level: .debug, message)
    }

    public static func info(_ message: String) { emit(level: .info, message) }
    public static func warning(_ message: String) { emit(level: .default, "⚠️ \(message)") }
    public static func error(_ message: String) { emit(level: .error, message) }
    public static func success(_ message: String) { emit(level: .default, message) }
}