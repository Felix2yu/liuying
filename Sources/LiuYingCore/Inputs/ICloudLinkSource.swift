import Foundation

/// 轮询 iCloud 里的链接文件，提取新增 URL。
///
/// 与旧版 Python 一一对应的行为：四类自动发现、`(mtime, size)` 签名、
/// 读取死线（iCloud 占位符首次读取会触发云端下载）、读取失败不更新签名、
/// 逐级探测区分「权限拦截」与「目录还没建」。
///
/// 新增的一条（实测必需）：**所有 iCloud 文件系统调用都带死线**。
/// TCC 待授权时 `opendir`/`open`/`stat` 会在 syscall 层无限阻塞，
/// 不设死线会让引擎和界面一起卡死。
public actor ICloudLinkSource {
    public struct Signature: Sendable, Equatable {
        public var mtimeNanoseconds: Int64
        public var size: Int64
    }

    public enum Status: Sendable, Equatable {
        case ok(path: String)
        case autoDiscovering(path: String)
        case notCreated(path: String)
        case permissionDenied(path: String)
        /// 调用超时，通常是在等系统授权。
        case permissionPending(path: String)
        case unreadable(path: String)
        case readTimedOut(path: String)

        public var displayText: String {
            switch self {
            case .ok(let path): "正常：\(path)"
            case .autoDiscovering(let path): "自动发现中：\(path)"
            case .notCreated(let path): "链接文件尚未创建：\(path)"
            case .permissionDenied(let path): "权限被拦截：\(path)"
            case .permissionPending(let path): "访问被系统挂起（可能在等授权）：\(path)"
            case .unreadable(let path): "无法读取：\(path)"
            case .readTimedOut(let path): "读取超时：\(path)"
            }
        }

        public var isHealthy: Bool {
            switch self {
            case .ok: true
            default: false
            }
        }

        /// 需要用户去系统设置授权的情况。
        public var needsAuthorization: Bool {
            switch self {
            case .permissionDenied, .permissionPending, .unreadable: true
            case .ok, .autoDiscovering, .notCreated, .readTimedOut: false
            }
        }
    }

    public private(set) var currentPath: String
    public private(set) var lastStatus: Status

    private let configuredPath: String
    private var lastSignature: Signature?
    private var lastBroadAttempt: Date?
    private var discoveryNeeded: Bool
    /// 访问被挂起时退避到什么时候。避免每轮都往 syscall 里撞 30 秒。
    private var suspendedUntil: Date?

    static let readTimeout: TimeInterval = 30
    static let statTimeout: TimeInterval = 5
    static let broadCooldown: TimeInterval = 600
    static let suspendDuration: TimeInterval = 300

    public init(configuredPath: String) {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespaces)
        self.configuredPath = trimmed
        if trimmed.isEmpty {
            self.currentPath = ICloudDiscovery.placeholderPath
            self.discoveryNeeded = true
            self.lastStatus = .autoDiscovering(path: ICloudDiscovery.placeholderPath)
        } else {
            self.currentPath = AppIdentity.expand(trimmed)
            self.discoveryNeeded = false
            self.lastStatus = .ok(path: AppIdentity.expand(trimmed))
        }
    }

    public func reconfigure(configuredPath: String) {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespaces)
        guard trimmed != configuredPath else { return }
        if trimmed.isEmpty {
            currentPath = ICloudDiscovery.placeholderPath
            discoveryNeeded = true
        } else {
            currentPath = AppIdentity.expand(trimmed)
            discoveryNeeded = false
        }
        lastSignature = nil
    }

    // MARK: - 采集

    public func collect() async -> [String] {
        // 上一次访问被系统挂起 → 退避期内直接跳过，别每轮都撞一次。
        if let until = suspendedUntil {
            guard Date() >= until else { return [] }
            suspendedUntil = nil
        }

        // 1. 需要发现，或配置的路径暂时不存在 → 找一次
        if discoveryNeeded {
            if let found = await discover() {
                adopt(found)
            } else {
                await diagnoseMissing()
                return []
            }
        }

        // 2. stat 带死线
        switch await statGuarded(currentPath) {
        case .timedOut:
            suspend(reason: "访问链接文件超时（可能在等系统授权）")
            return []
        case .missing:
            if let found = await discover() {
                adopt(found)
                return await collectFromCurrentPath()
            }
            await diagnoseMissing()
            return []
        case .ok(let signature):
            if signature == lastSignature { return [] }
            return await collectFromCurrentPath()
        }
    }

    /// 一次超时就退避 5 分钟，并明确告诉 UI 需要去系统设置授权。
    private func suspend(reason: String) {
        suspendedUntil = Date().addingTimeInterval(Self.suspendDuration)
        lastStatus = .permissionPending(path: currentPath)
        Log.warning("\(reason)；\(Int(Self.suspendDuration / 60)) 分钟后重试。路径：\(currentPath)")
    }

    private func collectFromCurrentPath() async -> [String] {
        switch await DeadlinedRead.text(at: currentPath, timeout: Self.readTimeout) {
        case .success(let text):
            lastStatus = .ok(path: currentPath)
            suspendedUntil = nil
            lastSignature = await signature()
            let urls = URLExtractor.extract(from: text)
            if !urls.isEmpty {
                Log.info("采集到 \(urls.count) 条链接（\(currentPath)）")
            }
            return urls
        case .timeout:
            suspend(reason: "读取链接文件超时（\(Int(Self.readTimeout))s）")
            return []
        case .failure(let message):
            lastStatus = .unreadable(path: currentPath)
            Log.warning("读取链接文件失败：\(message)")
            return []
        }
    }

    private func adopt(_ path: String) {
        if path != currentPath {
            Log.info("链接文件路径变更：\(currentPath) → \(path)")
        }
        currentPath = path
        discoveryNeeded = false
        lastSignature = nil
        lastStatus = .ok(path: path)
    }

    // MARK: - 发现与诊断

    private func discover() async -> String? {
        if let found = await ICloudDiscovery.discoverNarrow() { return found }
        let now = Date()
        if let last = lastBroadAttempt, now.timeIntervalSince(last) < Self.broadCooldown { return nil }
        lastBroadAttempt = now
        return await ICloudDiscovery.discoverBroad()
    }

    /// 逐级向上探测，区分「权限拦截 / 待授权」与「目录还没建」。
    /// 必须用 `opendir` 而不是 `stat`：stat 能成功不代表能列目录（TCC 拦的正是列举/读取）。
    public func diagnoseMissing() async {
        var path = currentPath
        while true {
            switch await listGuarded(path) {
            case .timedOut:
                lastStatus = .permissionPending(path: path)
                Log.warning("探测目录超时（可能在等系统授权）：\(path)")
                return
            case .denied:
                lastStatus = .permissionDenied(path: path)
                Log.error("权限被拦截：无法访问 \(path)。请在系统设置「完全磁盘访问权限」中授权 \(AppIdentity.displayName).app。")
                return
            case .unreadable(let message):
                lastStatus = .unreadable(path: path)
                Log.warning("无法检查目录 \(path)：\(message)")
                return
            case .missing:
                let parent = (path as NSString).deletingLastPathComponent
                if parent == path {
                    lastStatus = .notCreated(path: currentPath)
                    return
                }
                path = parent
            case .ok:
                lastStatus = .notCreated(path: currentPath)
                Log.info("链接文件尚不存在：\(currentPath)")
                return
            }
        }
    }

    // MARK: - 签名

    private enum StatOutcome {
        case ok(Signature)
        case missing
        case timedOut
    }

    private enum ListOutcome {
        case ok
        case missing
        case denied
        case unreadable(String)
        case timedOut
    }

    private struct RawStat: Sendable {
        var signature: Signature?
        var errno: Int32
    }

    private enum RawList: Sendable {
        case ok
        case missing
        case denied
        case unreadable(String)
    }

    private func statGuarded(_ path: String) async -> StatOutcome {
        let raw = await GuardedFS.value(timeout: Self.statTimeout) {
            var info = stat()
            if stat(path, &info) == 0 {
                return RawStat(
                    signature: Signature(
                        mtimeNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                            + Int64(info.st_mtimespec.tv_nsec),
                        size: Int64(info.st_size)
                    ),
                    errno: 0
                )
            }
            return RawStat(signature: nil, errno: errno)
        }
        guard let raw else { return .timedOut }
        guard let signature = raw.signature else { return .missing }
        return .ok(signature)
    }

    private func listGuarded(_ path: String) async -> ListOutcome {
        let raw = await GuardedFS.value(timeout: Self.statTimeout) {
            errno = 0
            guard let directory = opendir(path) else {
                switch errno {
                case ENOENT: return RawList.missing
                case EPERM, EACCES: return RawList.denied
                default: return RawList.unreadable(String(cString: strerror(errno)))
                }
            }
            closedir(directory)
            return RawList.ok
        }
        guard let raw else { return .timedOut }
        switch raw {
        case .ok: return .ok
        case .missing: return .missing
        case .denied: return .denied
        case .unreadable(let message): return .unreadable(message)
        }
    }

    public func signature() async -> Signature? {
        switch await statGuarded(currentPath) {
        case .ok(let signature): signature
        default: nil
        }
    }

    /// 我们自己在文件上写过之后调用：清掉签名，让下一轮重新读。
    public func invalidateSignature() {
        lastSignature = nil
    }

    public var status: Status { lastStatus }
    public var path: String { currentPath }
}