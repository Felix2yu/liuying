import Foundation

public enum BackendKind: String, Codable, Sendable, CaseIterable {
    /// B 站后端：内嵌的 liuying-engine（Go CLI，兼容 yutto argv）。rawValue 用带连字符的名字，
    /// 旧配置里写的 "yutto" 由自定义解码迁移到这里。
    case biliDL = "liuying-engine"
    case downie

    public var displayName: String {
        switch self {
        case .biliDL: "liuying-engine"
        case .downie: "Downie"
        }
    }

    /// 旧配置里的 `"yutto"`、仓库改名前的 `"bili-dl"` 都迁移到 liuying-engine；
    /// 其它未知值按损坏值抛错，由调用方的 `value(_:fallback:)` 回退到各自默认值。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "yutto" || raw == "bili-dl" {
            self = .biliDL
            return
        }
        guard let kind = BackendKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "未知后端：\(raw)"
            )
        }
        self = kind
    }
}

/// liuying-engine 段配置。默认值对齐原 yutto 的 DEFAULT_CONFIG，liuying-engine 接受同一套 argv。
public struct BiliDlConfig: Codable, Sendable, Equatable {
    /// 留空 / 默认名都优先用 .app 内嵌的 liuying-engine；填绝对路径可覆盖。
    public var binary = "liuying-engine"
    public var videoQuality = 127
    public var audioQuality = 30_280
    public var vcodec = "av1:copy"
    public var vcodecPriority = ["av1", "hevc", "avc"]
    public var outputFormat = "mp4"
    public var subpathTemplate = "{owner_uname}/{title}"
    public var downloadAllPages = true
    public var downloadDanmaku = false
    public var downloadSubtitle = false
    public var saveCover = false
    /// liuying-engine 直接读 yutto 的 auth.toml（[profiles.<name>].sessdata），保持登录态零迁移。
    public var authFile = "~/.config/yutto/auth.toml"
    public var authProfile = "default"
    public var extraArgs: [String] = []
    /// 最终封装容器按视频编码决定；无损音轨装不进 mp4/mov 时会退回 mkv。
    public var outputContainers = ["av1": "mkv", "hevc": "mov", "avc": "mp4"]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case binary
        case videoQuality = "video_quality"
        case audioQuality = "audio_quality"
        case vcodec
        case vcodecPriority = "vcodec_priority"
        case outputFormat = "output_format"
        case subpathTemplate = "subpath_template"
        case downloadAllPages = "download_all_pages"
        case downloadDanmaku = "download_danmaku"
        case downloadSubtitle = "download_subtitle"
        case saveCover = "save_cover"
        case authFile = "auth_file"
        case authProfile = "auth_profile"
        case extraArgs = "extra_args"
        case outputContainers = "output_containers"
    }

    /// 手写解码：缺键或类型不对都退回默认值。旧 config.json 只有部分键，必须能读。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BiliDlConfig()
        binary = c.value(.binary, d.binary)
        videoQuality = c.value(.videoQuality, d.videoQuality)
        audioQuality = c.value(.audioQuality, d.audioQuality)
        vcodec = c.value(.vcodec, d.vcodec)
        vcodecPriority = c.value(.vcodecPriority, d.vcodecPriority)
        outputFormat = c.value(.outputFormat, d.outputFormat)
        subpathTemplate = c.value(.subpathTemplate, d.subpathTemplate)
        downloadAllPages = c.value(.downloadAllPages, d.downloadAllPages)
        downloadDanmaku = c.value(.downloadDanmaku, d.downloadDanmaku)
        downloadSubtitle = c.value(.downloadSubtitle, d.downloadSubtitle)
        saveCover = c.value(.saveCover, d.saveCover)
        authFile = c.value(.authFile, d.authFile)
        authProfile = c.value(.authProfile, d.authProfile)
        extraArgs = c.value(.extraArgs, d.extraArgs)
        outputContainers = c.value(.outputContainers, d.outputContainers)
    }
}

public struct DownieConfig: Codable, Sendable, Equatable {
    public var appName = "Downie 4"
    public var postprocessing = "mp4"
    public var destination = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case postprocessing
        case destination
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DownieConfig()
        appName = c.value(.appName, d.appName)
        postprocessing = c.value(.postprocessing, d.postprocessing)
        destination = c.value(.destination, d.destination)
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    /// 留空表示自动发现（iOS 快捷指令写的是它自己的 iCloud app 容器）。
    public var watchFile = ""
    public var pollInterval = 15
    public var downloadDir = "~/Downloads/Bilibili"
    /// B 站主机（b23.tv / bilibili.com / bilibili.tv）走哪个后端。默认内嵌 liuying-engine。
    public var bilibiliBackend: BackendKind = .biliDL
    /// 其余 http(s) 链接走哪个后端。默认 Downie —— liuying-engine 只认 B 站。
    public var otherBackend: BackendKind = .downie
    public var maxTasksPerRound = 20
    public var notify = true
    /// 默认关闭：剪贴板是环境输入，自动触发下载要用户主动开。
    public var clipboardMonitor = false
    /// 主窗口聚焦时按 ⌘V 直接下载剪贴板里的链接。显式手势，默认开；
    /// 输入框聚焦、sheet、非主窗口时一律放行，不影响普通粘贴。
    public var pasteShortcut = true
    /// UP 主订阅轮询间隔（秒）。
    public var subscriptionInterval = 1_800
    /// 手动覆盖 SESSDATA；留空则从 auth.toml 读。
    public var sessdataOverride = ""
    /// 单次 liuying-engine 调用超时（秒）。旧版用环境变量 BILI_WATCHER_TIMEOUT，默认 3600。
    public var biliDLTimeout = 3_600
    /// 跨设备去重同步：把已入队链接的键写进 links.txt 同目录的清单随 iCloud 同步，
    /// 新机启动先导入，避免空库把 links.txt 里的旧链接全部重新下载。
    public var dedupSync = true

    public var biliDL = BiliDlConfig()
    public var downie = DownieConfig()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case watchFile = "watch_file"
        case pollInterval = "poll_interval"
        case downloadDir = "download_dir"
        case bilibiliBackend = "bilibili_backend"
        case otherBackend = "other_backend"
        case maxTasksPerRound = "max_tasks_per_round"
        case notify
        case clipboardMonitor = "clipboard_monitor"
        case pasteShortcut = "paste_shortcut"
        case subscriptionInterval = "subscription_interval"
        case sessdataOverride = "sessdata_override"
        case biliDLTimeout = "bili_dl_timeout"
        case dedupSync = "dedup_sync"
        case biliDL = "bili_dl"
        case downie

        // 旧键：只在解码时读一次，编码一律写新键。
        case legacyYutto = "yutto"
        case legacyYuttoTimeout = "yutto_timeout"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        watchFile = c.value(.watchFile, d.watchFile)
        pollInterval = c.value(.pollInterval, d.pollInterval)
        downloadDir = c.value(.downloadDir, d.downloadDir)
        bilibiliBackend = c.value(.bilibiliBackend, d.bilibiliBackend)
        otherBackend = c.value(.otherBackend, d.otherBackend)
        maxTasksPerRound = c.value(.maxTasksPerRound, d.maxTasksPerRound)
        notify = c.value(.notify, d.notify)
        clipboardMonitor = c.value(.clipboardMonitor, d.clipboardMonitor)
        pasteShortcut = c.value(.pasteShortcut, d.pasteShortcut)
        subscriptionInterval = c.value(.subscriptionInterval, d.subscriptionInterval)
        sessdataOverride = c.value(.sessdataOverride, d.sessdataOverride)
        dedupSync = c.value(.dedupSync, d.dedupSync)

        // 新键优先，旧键迁移：bili_dl_timeout ← yutto_timeout；bili_dl ← yutto。
        if let timeout = c.valueOptional(.biliDLTimeout, Int.self) {
            biliDLTimeout = timeout
        } else {
            biliDLTimeout = c.value(.legacyYuttoTimeout, d.biliDLTimeout)
        }
        if let legacy = c.valueOptional(.legacyYutto, BiliDlConfig.self) {
            // 新段缺席时用旧 yutto 段；新段存在则用新段（下面覆盖）。
            biliDL = legacy
        } else {
            biliDL = d.biliDL
        }
        biliDL = c.value(.biliDL, biliDL)
        downie = c.value(.downie, d.downie)
    }

    /// 夹取到可用范围。UI 的 Stepper 与手工编辑都要经过这里。
    public mutating func normalize() {
        pollInterval = min(max(pollInterval, 5), 3_600)
        maxTasksPerRound = min(max(maxTasksPerRound, 1), 100)
        subscriptionInterval = min(max(subscriptionInterval, 60), 86_400)
        biliDLTimeout = min(max(biliDLTimeout, 60), 86_400)
        if downloadDir.trimmingCharacters(in: .whitespaces).isEmpty {
            downloadDir = AppConfig().downloadDir
        }
        if biliDL.vcodecPriority.isEmpty {
            biliDL.vcodecPriority = AppConfig().biliDL.vcodecPriority
        }
        if biliDL.subpathTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            biliDL.subpathTemplate = AppConfig().biliDL.subpathTemplate
        }
    }

    /// 按链接选后端：内嵌引擎支持的站点（B 站、X）走 liuying-engine，其余交给 Downie。
    /// 这是**路由**，不是「失败后回退」——后端在任务开始下载时按当前配置选定，
    /// 入队后没有单独持久化，排队中的任务改设置会跟着换。
    public func backend(for url: String) -> BackendKind {
        URLExtractor.usesEmbeddedEngine(url) ? bilibiliBackend : otherBackend
    }

    /// 旧版 config.json 的形状，用于首次启动导入历史设置。
    public static func decode(fromJSON data: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// 手写编码：只写新键，旧键（yutto / yutto_timeout）不再输出，避免迁移后又把旧值写回去。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(watchFile, forKey: .watchFile)
        try c.encode(pollInterval, forKey: .pollInterval)
        try c.encode(downloadDir, forKey: .downloadDir)
        try c.encode(bilibiliBackend, forKey: .bilibiliBackend)
        try c.encode(otherBackend, forKey: .otherBackend)
        try c.encode(maxTasksPerRound, forKey: .maxTasksPerRound)
        try c.encode(notify, forKey: .notify)
        try c.encode(clipboardMonitor, forKey: .clipboardMonitor)
        try c.encode(pasteShortcut, forKey: .pasteShortcut)
        try c.encode(subscriptionInterval, forKey: .subscriptionInterval)
        try c.encode(sessdataOverride, forKey: .sessdataOverride)
        try c.encode(biliDLTimeout, forKey: .biliDLTimeout)
        try c.encode(dedupSync, forKey: .dedupSync)
        try c.encode(biliDL, forKey: .biliDL)
        try c.encode(downie, forKey: .downie)
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

private extension KeyedDecodingContainer {
    /// 缺键、类型不符、显式 null 一律退回默认值 —— 与旧版「无校验、坏了就用默认」的行为一致。
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func valueOptional<T: Decodable>(_ key: Key, _: T.Type) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}

/// B 站画质/音质档位。数值与 yutto 2.2.0 的 `--help` 一致，liuying-engine 接受同一套 qn/id。
public enum BiliQuality {
    public static let videoOptions: [(value: Int, label: String)] = [
        (127, "8K"), (126, "杜比视界"), (125, "4K·HDR10"), (120, "4K"),
        (116, "1080P60"), (112, "1080P+"), (100, "智能修复"), (80, "1080P"),
        (74, "720P60"), (64, "720P"), (32, "480P"), (16, "360P"),
    ]

    public static let audioOptions: [(value: Int, label: String)] = [
        (30_251, "Hi-Res"), (30_255, "Dolby Audio"), (30_250, "Dolby Atmos"),
        (30_280, "320kbps"), (30_232, "128kbps"), (30_216, "64kbps"),
    ]

    public static let outputFormats = ["infer", "mp4", "mkv", "mov"]
    public static let containers = ["mkv", "mov", "mp4"]
    public static let downiePostprocessing = ["mp4", "audio", "permute"]

    public static func videoLabel(_ value: Int) -> String {
        videoOptions.first(where: { $0.value == value }).map { "\($0.value) · \($0.label)" } ?? "\(value)"
    }

    public static func audioLabel(_ value: Int) -> String {
        audioOptions.first(where: { $0.value == value }).map { "\($0.value) · \($0.label)" } ?? "\(value)"
    }
}
