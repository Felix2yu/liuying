import Foundation

public enum TaskState: String, Codable, Sendable, CaseIterable {
    case pending
    case downloading
    case done
    case failed

    public var displayName: String {
        switch self {
        case .pending: "待处理"
        case .downloading: "下载中"
        case .done: "已完成"
        case .failed: "失败"
        }
    }
}

public enum TaskSource: String, Codable, Sendable, CaseIterable {
    case icloud
    /// 用户在 App 里手动粘贴/拖入。
    case manual
    case clipboard
    case subscription

    public var displayName: String {
        switch self {
        case .icloud: "iCloud"
        case .manual: "手动"
        case .clipboard: "剪贴板"
        case .subscription: "订阅"
        }
    }
}

/// 一次下载产出的一个文件。多 P 视频会有多行 —— 旧版只记 `sorted(new)[-1]`，这是明确的 bug。
public struct TaskOutput: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var taskID: Int64
    public var path: String
    public var kind: String
    public var bytes: Int64?

    public init(id: Int64 = 0, taskID: Int64 = 0, path: String, kind: String = "video", bytes: Int64? = nil) {
        self.id = id
        self.taskID = taskID
        self.path = path
        self.kind = kind
        self.bytes = bytes
    }
}

public struct DownloadTask: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var rawURL: String
    public var taskKey: String
    public var bvid: String?
    public var title: String?
    public var ownerName: String?
    public var ownerMid: Int64?
    public var state: TaskState
    public var attempts: Int
    public var backend: String?
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var source: TaskSource
    public var subscriptionID: Int64?
    public var pubdate: Date?
    public var duration: Int?
    public var pageCount: Int?
    public var outputs: [TaskOutput]

    /// 队列行优先显示标题，退化为 BV，再退化为原始链接。
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let bvid, !bvid.isEmpty { return bvid }
        return rawURL
    }
}

/// 待入库的一条新任务。
public struct NewTask: Sendable {
    public var rawURL: String
    public var taskKey: String
    public var source: TaskSource
    public var subscriptionID: Int64?
    public var bvid: String?
    public var title: String?
    public var ownerName: String?
    public var ownerMid: Int64?
    public var pubdate: Date?
    public var duration: Int?
    public var pageCount: Int?

    public init(
        rawURL: String,
        taskKey: String,
        source: TaskSource,
        subscriptionID: Int64? = nil,
        bvid: String? = nil,
        title: String? = nil,
        ownerName: String? = nil,
        ownerMid: Int64? = nil,
        pubdate: Date? = nil,
        duration: Int? = nil,
        pageCount: Int? = nil
    ) {
        self.rawURL = rawURL
        self.taskKey = taskKey
        self.source = source
        self.subscriptionID = subscriptionID
        self.bvid = bvid
        self.title = title
        self.ownerName = ownerName
        self.ownerMid = ownerMid
        self.pubdate = pubdate
        self.duration = duration
        self.pageCount = pageCount
    }
}
