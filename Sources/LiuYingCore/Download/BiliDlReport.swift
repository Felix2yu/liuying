import Foundation

/// liuying-engine `--progress-json` 的 NDJSON 单行事件。
///
/// 只声明用得到的字段：未知字段由 Decodable 自动忽略，
/// 这样 Go 侧新增字段不会让旧客户端解析失败。
public struct BiliDlEvent: Decodable, Sendable {
    public var event: String
    public var mediaID: String?
    public var bv: String?
    public var page: Int?
    public var kind: String?
    public var current: Int64?
    public var total: Int64?
    public var percent: Double?
    public var speedBPS: Int64?
    public var message: String?
    public var outputs: [BiliDlOutput]?

    enum CodingKeys: String, CodingKey {
        case event
        case mediaID = "media_id"
        case bv, page, kind, current, total, percent, message, outputs
        case speedBPS = "speed_bps"
    }

    /// 解析一行文本；不是 JSON 对象时返回 nil（普通日志行走这条路）。
    public static func parse(line: String) -> BiliDlEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BiliDlEvent.self, from: data)
    }

    public var progress: DownloadProgress {
        DownloadProgress(
            kind: kind ?? "",
            current: current ?? 0,
            total: total ?? 0,
            percent: percent ?? 0,
            speedBPS: speedBPS ?? 0
        )
    }
}

/// 一条已落盘的产物。
public struct BiliDlOutput: Decodable, Sendable {
    public var path: String
    public var kind: String
    public var container: String?
    public var bytes: Int64?

    public init(path: String, kind: String, container: String? = nil, bytes: Int64? = nil) {
        self.path = path
        self.kind = kind
        self.container = container
        self.bytes = bytes
    }
}

/// `--result-json` 的逐目标明细。
public struct BiliDlTargetReport: Decodable, Sendable {
    public var mediaID: String?
    public var bv: String?
    public var page: Int?
    public var title: String?
    public var state: String
    public var outputs: [BiliDlOutput]?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case bv, page, title, state, outputs, error
    }
}

/// `--result-json` 写出的完整结果。
public struct BiliDlReport: Decodable, Sendable {
    public var version: String
    public var generatedAt: String?
    public var state: String
    public var outputs: [BiliDlOutput]
    public var targets: [BiliDlTargetReport]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case state, outputs, targets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        generatedAt = try? c.decode(String.self, forKey: .generatedAt)
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        // outputs 在 Go 侧永远是数组，但旧版本可能完全没有这个键。
        outputs = (try? c.decode([BiliDlOutput].self, forKey: .outputs)) ?? []
        targets = (try? c.decode([BiliDlTargetReport].self, forKey: .targets)) ?? []
    }

    /// 读取结果文件；文件不存在或不是合法 JSON 时返回 nil。
    /// 返回 nil 表示「这批 liuying-engine 不支持 --result-json」，调用方应回退到目录差集。
    public static func load(path: String) -> BiliDlReport? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(BiliDlReport.self, from: data)
    }

    /// 失败目标的错误摘要，用于拼给人看的提示。
    public var failureSummary: String? {
        let messages = targets.compactMap { $0.error }.filter { !$0.isEmpty }
        guard !messages.isEmpty else { return nil }
        if messages.count == 1 { return messages[0] }
        return "\(messages.count) 个目标失败：" + messages.joined(separator: "；")
    }
}
