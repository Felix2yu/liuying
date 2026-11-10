import Foundation
import Observation

/// 引擎对外发布的只读快照。UI 只读这个，不直接碰引擎内部状态。
public struct EngineSnapshot: Sendable, Equatable {
    public var isRunning = false
    public var isPaused = false
    public var stats: [TaskState: Int] = [:]
    public var currentTaskID: Int64?
    public var currentText: String?
    public var currentLog: [String] = []
    public var lastRoundAt: Date?
    public var lastError: String?
    public var linkStatusText = ""
    public var linkStatusHealthy = true
    public var pendingPruneCount = 0
    public var pruneFailure: String?
    public var recent: [DownloadTask] = []
    /// 快照里最多带多少条历史；队列页可「加载更多」把它抬高。
    public var recentLimit = 30
    /// 是否还有没装进快照的更旧任务。
    public var recentTruncated = false
    /// 每次有任务确认完成就 +1；视频库据此主动失效缓存并重新扫描。
    public var libraryRevision = 0

    public var pendingCount: Int { stats[.pending] ?? 0 }
    public var downloadingCount: Int { stats[.downloading] ?? 0 }
    public var failedCount: Int { stats[.failed] ?? 0 }
    public var doneCount: Int { stats[.done] ?? 0 }

    public var statusLine: String {
        if isPaused { return "已暂停" }
        if let currentText, downloadingCount > 0 { return "下载中：\(currentText)" }
        if downloadingCount > 0 { return "下载中 \(downloadingCount)" }
        if pendingCount > 0 { return "待处理 \(pendingCount)" }
        return "空闲"
    }
}

/// UI 侧的可观察镜像。
@MainActor
@Observable
public final class EngineModel {
    public private(set) var snapshot = EngineSnapshot()

    public init() {}

    public func apply(_ new: EngineSnapshot) {
        snapshot = new
    }
}

/// 通知钩子。真实现（UNUserNotificationCenter）在 App target 里，引擎不依赖它。
public protocol EngineNotifying: Sendable {
    func taskAdded(title: String, url: String) async
    func taskFinished(title: String, outputPaths: [String]) async
    func taskFailed(title: String, error: String) async
    func message(_ text: String) async
}

public struct NoopNotifier: EngineNotifying {
    public init() {}
    public func taskAdded(title: String, url: String) async {}
    public func taskFinished(title: String, outputPaths: [String]) async {}
    public func taskFailed(title: String, error: String) async {}
    public func message(_ text: String) async {}
}