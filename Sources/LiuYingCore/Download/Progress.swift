import Foundation

/// 一次下载动作的进度快照，来自 bili-dl 的 `--progress-json` NDJSON 事件。
///
/// 只保留 UI 需要的字段：`kind` 用来区分视频流/音频流/封面等，
/// `percent` 是单文件百分比（多 P 任务会逐个文件从 0 走到 100）。
public struct DownloadProgress: Sendable, Equatable {
    public var kind: String
    public var current: Int64
    public var total: Int64
    public var percent: Double
    public var speedBPS: Int64

    public init(
        kind: String = "", current: Int64 = 0, total: Int64 = 0,
        percent: Double = 0, speedBPS: Int64 = 0
    ) {
        self.kind = kind
        self.current = current
        self.total = total
        self.percent = percent
        self.speedBPS = speedBPS
    }

    /// 形如「视频流 45% · 3.2 MB/s」。进度未知时只回类型名。
    public var displayText: String {
        var parts: [String] = []
        if !kind.isEmpty { parts.append(Self.kindLabel(kind)) }
        if percent > 0 {
            parts.append(String(format: "%.0f%%", percent))
        } else if total > 0 {
            parts.append(Self.bytes(current) + " / " + Self.bytes(total))
        }
        if speedBPS > 0 {
            parts.append(Self.bytes(speedBPS) + "/s")
        }
        return parts.joined(separator: " · ")
    }

    private static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "video": return "视频流"
        case "audio": return "音频流"
        case "cover": return "封面"
        case "danmaku": return "弹幕"
        case "subtitle": return "字幕"
        case "image": return "图片"
        default: return kind
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// 线程安全的进度容器。
///
/// 进度回调来自 Subprocess 的后台队列，引擎与 UI 会并发读它，
/// 所以不能直接用 `@Observable` 的属性承载（与 LogTail 同一套路数）。
public final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DownloadProgress?

    public init() {}

    public func update(_ progress: DownloadProgress) {
        lock.lock()
        value = progress
        lock.unlock()
    }

    public var latest: DownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func clear() {
        lock.lock(); value = nil; lock.unlock()
    }
}
