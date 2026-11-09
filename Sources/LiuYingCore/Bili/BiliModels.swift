import Foundation

public struct BiliVideo: Sendable, Hashable {
    public var bvid: String
    public var aid: Int64?
    public var title: String
    public var coverURL: String?
    /// 接口给的是 `"MM:SS"` 字符串。
    public var length: String?
    public var created: Date?
    /// 投稿简介，订阅列表里用不到，留给后续展示。
    public var summary: String?

    public init(
        bvid: String, aid: Int64? = nil, title: String,
        coverURL: String? = nil, length: String? = nil,
        created: Date? = nil, summary: String? = nil
    ) {
        self.bvid = bvid
        self.aid = aid
        self.title = title
        self.coverURL = coverURL
        self.length = length
        self.created = created
        self.summary = summary
    }

    /// 投稿页地址，直接喂给 yutto。
    public var pageURL: String { "https://www.bilibili.com/video/\(bvid)" }
}

public struct BiliPage: Sendable, Hashable {
    public var page: Int
    public var cid: Int64?
    public var part: String
    public var duration: Int?

    public init(page: Int, cid: Int64? = nil, part: String, duration: Int? = nil) {
        self.page = page
        self.cid = cid
        self.part = part
        self.duration = duration
    }
}

public struct BiliVideoDetail: Sendable {
    public var bvid: String
    public var aid: Int64?
    public var title: String
    public var coverURL: String?
    public var pubdate: Date?
    /// 整条视频总时长（秒）。
    public var duration: Int?
    public var ownerName: String?
    public var ownerMid: Int64?
    public var pages: [BiliPage]

    public init(
        bvid: String, aid: Int64? = nil, title: String, coverURL: String? = nil,
        pubdate: Date? = nil, duration: Int? = nil, ownerName: String? = nil,
        ownerMid: Int64? = nil, pages: [BiliPage] = []
    ) {
        self.bvid = bvid
        self.aid = aid
        self.title = title
        self.coverURL = coverURL
        self.pubdate = pubdate
        self.duration = duration
        self.ownerName = ownerName
        self.ownerMid = ownerMid
        self.pages = pages
    }
}

public struct ArcPage: Sendable {
    public var videos: [BiliVideo]
    public var totalCount: Int
    public var pageNumber: Int
    public var pageSize: Int

    public init(videos: [BiliVideo], totalCount: Int, pageNumber: Int, pageSize: Int) {
        self.videos = videos
        self.totalCount = totalCount
        self.pageNumber = pageNumber
        self.pageSize = pageSize
    }
}

public enum BiliError: Error, LocalizedError, Sendable {
    case http(Int, String)
    case api(code: Int, message: String)
    case riskControl(code: Int, message: String)
    case decoding(String)
    case missingWBIKeys

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            "HTTP \(status)" + (body.isEmpty ? "" : "：\(body)")
        case .api(let code, let message): "B 站接口错误 \(code)：\(message)"
        case .riskControl(let code, let message):
            "B 站风控拦截 \(code)：\(message)。需要有效的 SESSDATA（yutto 的 auth.toml），或请求过于频繁。"
        case .decoding(let detail): "响应解析失败：\(detail)"
        case .missingWBIKeys: "拿不到 WBI 签名密钥"
        }
    }

    /// 熔断计数只针对风控/接口错误，解析错误重试也没意义。
    public var isRiskControl: Bool {
        switch self {
        case .riskControl: true
        case .http(let status, _): status == 412
        default: false
        }
    }
}
