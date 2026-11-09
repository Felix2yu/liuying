import Foundation

/// 主编排器：轮询 → 去重入队 → 串行下载 → 容器规整 → 删链接 → 通知。
///
/// 串行下载是刻意的（与旧版一致）：并发下载既抢带宽，也更容易触发 B 站风控。
public actor Engine {
    public typealias SnapshotSink = @Sendable (EngineSnapshot) -> Void

    private let store: TaskStore
    private let keyResolver = KeyResolver()
    private let clipboard = ClipboardMonitor()
    private var config: AppConfig
    private var linkSource: ICloudLinkSource
    private var biliClient: BiliClient
    private var notifier: any EngineNotifying
    private var subscriptionPoller: SubscriptionPoller?
    private var lastSubscriptionPoll: Date?

    private var snapshot = EngineSnapshot()
    private var sink: SnapshotSink?
    private var loopTask: Task<Void, Never>?
    private var paused = false
    private var tickRequested = false
    private var currentHandle: ProcessHandle?
    private var logTail = LogTail()

    /// 下载成功后待从 links.txt 清掉的 URL / canonical key。
    private var pendingPrune: Set<String> = []
    private var pruneFailures = 0
    private var nextPruneAllowedAt = Date.distantPast

    public init(
        store: TaskStore,
        config: AppConfig,
        notifier: any EngineNotifying = NoopNotifier(),
        subscriptionPoller: SubscriptionPoller? = nil
    ) {
        self.store = store
        self.config = config
        self.notifier = notifier
        self.subscriptionPoller = subscriptionPoller
        self.linkSource = ICloudLinkSource(configuredPath: config.watchFile)
        self.biliClient = BiliClient(sessdata: Self.resolveSessdata(config))
    }

    // MARK: - 配置

    public func updateConfig(_ newConfig: AppConfig) {
        config = newConfig
        Task {
            await linkSource.reconfigure(configuredPath: newConfig.watchFile)
            await biliClient.updateSessdata(Self.resolveSessdata(newConfig))
        }
    }

    public func setNotifier(_ notifier: any EngineNotifying) {
        self.notifier = notifier
    }

    public func setSnapshotSink(_ sink: SnapshotSink?) {
        self.sink = sink
        Task { await publish() }
    }

    public static func resolveSessdata(_ config: AppConfig) -> String? {
        AuthFile.resolveSessdata(
            override: config.sessdataOverride,
            path: config.yutto.authFile,
            profile: config.yutto.authProfile
        )
    }

    // MARK: - 生命周期

    public func start() {
        guard loopTask == nil else { return }
        paused = false
        snapshot.isRunning = true
        snapshot.isPaused = false
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        Log.info("引擎启动：轮询 \(max(5, config.pollInterval))s")
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        currentHandle?.cancel()
        snapshot.isRunning = false
        Task { await publish() }
        Log.info("引擎已停止")
    }

    public func pause() {
        paused = true
        snapshot.isPaused = true
        Task { await publish() }
        Log.info("引擎已暂停")
    }

    public func resume() {
        paused = false
        snapshot.isPaused = false
        tickRequested = true
        Task { await publish() }
        Log.info("引擎已继续")
    }

    /// 立刻跑一轮（睡眠唤醒、菜单「立即检查」、登录后补跑）。
    public func tickNow() {
        tickRequested = true
    }

    public func cancelCurrentDownload() {
        currentHandle?.cancel()
    }

    // MARK: - 主循环

    private func runLoop() async {
        while !Task.isCancelled {
            await runRound()
            let interval = max(5, config.pollInterval)
            let deadline = Date().addingTimeInterval(TimeInterval(interval))
            while Date() < deadline, !Task.isCancelled, !tickRequested {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            tickRequested = false
        }
    }

    private func runRound() async {
        do {
            _ = try await ingestOnce()
            if !paused {
                _ = try await processOnce()
            }
            await flushPrune()
            snapshot.lastError = nil
        } catch {
            snapshot.lastError = error.localizedDescription
            Log.error("主循环异常：\(error)")
        }
        snapshot.lastRoundAt = Date()
        await publish()
    }

    /// 手动触发一轮（不含睡眠）。
    public func runOnce() async {
        await runRound()
    }

    // MARK: - 采集

    @discardableResult
    private func ingestOnce() async throws -> Int {
        var added = 0
        let urls = await linkSource.collect()
        added += try await enqueue(urls: urls, source: .icloud)

        if config.clipboardMonitor {
            let copied = clipboard.poll()
            if !copied.isEmpty {
                added += try await enqueue(urls: copied, source: .clipboard)
            }
        }

        let status = await linkSource.status
        snapshot.linkStatusText = status.displayText
        snapshot.linkStatusHealthy = status.isHealthy

        added += await ingestSubscriptions()
        return added
    }

    private func enqueue(
        urls: [String],
        source: TaskSource,
        subscriptionID: Int64? = nil,
        metadata: [String: BiliVideo] = [:]
    ) async throws -> Int {
        guard !urls.isEmpty else { return 0 }
        var known = try await store.knownKeys()
        var added = 0
        for url in urls {
            let key = await keyResolver.key(for: url)
            guard !known.contains(key) else { continue }
            let video = metadata[key]
            let newTask = NewTask(
                rawURL: url,
                taskKey: key,
                source: source,
                subscriptionID: subscriptionID,
                bvid: video?.bvid ?? CanonicalKey.localKey(url),
                title: video?.title,
                pubdate: video?.created
            )
            if (try await store.add(newTask)) != nil {
                known.insert(key)
                added += 1
                Log.info("新链接入队：\(url)（键 \(key)，来源 \(source.displayName)）")
                await notifier.taskAdded(title: video?.title ?? key, url: url)
            }
        }
        return added
    }

    /// App 内手动添加：粘贴一整段分享文案也认。
    @discardableResult
    public func addManual(text: String) async -> Int {
        let urls = URLExtractor.extract(from: text)
        guard !urls.isEmpty else { return 0 }
        do {
            let added = try await enqueue(urls: urls, source: .manual)
            await publish()
            return added
        } catch {
            Log.error("手动添加入队失败：\(error)")
            return 0
        }
    }

    // MARK: - 下载

    private func processOnce() async throws -> Int {
        var completed = 0
        while !paused, !Task.isCancelled {
            let claimed = try await store.claim(limit: 1)
            guard let task = claimed.first else { break }
            if await process(task: task) { completed += 1 }
        }
        return completed
    }

    /// - Returns: 是否下载成功。
    private func process(task: DownloadTask) async -> Bool {
        let workDir = (AppIdentity.workDirectory as NSString).appendingPathComponent("task-\(task.id)")
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }

        // 尽力取标题/UP 主：旧版 title 永远是空的，这里补上。
        var title = task.title
        var ownerName = task.ownerName
        var bvid = task.bvid
        if let candidate = bvid ?? CanonicalKey.localKey(task.rawURL), candidate.hasPrefix("BV") {
            if let detail = try? await biliClient.view(bvid: candidate) {
                title = detail.title
                ownerName = detail.ownerName
                bvid = detail.bvid
                try? await store.setMetadata(
                    id: task.id, bvid: detail.bvid, title: detail.title,
                    ownerName: detail.ownerName, ownerMid: detail.ownerMid,
                    duration: detail.duration, pageCount: detail.pages.count
                )
            }
        }

        let display = title ?? bvid ?? task.rawURL
        logTail.clear()
        snapshot.currentTaskID = task.id
        snapshot.currentText = display
        await publish()

        let handle = ProcessHandle()
        currentHandle = handle
        let backend = makeBackend(for: task.rawURL)
        Log.info("开始下载 [\(task.attempts)/3] \(display)（\(backend.name)）")

        // 闭包在后台私有队列上被调用，不能直接碰 actor 状态；LogTail 自己是线程安全的。
        let tail = logTail
        let result = await backend.download(
            url: task.rawURL, workDir: workDir, handle: handle
        ) { line in
            tail.append(line)
        }

        currentHandle = nil
        snapshot.currentTaskID = nil
        snapshot.currentText = nil

        if result.cancelled {
            try? await store.retryLater(id: task.id, error: "已取消")
            Log.warning("下载已取消：\(display)")
            await publish()
            return false
        }

        if result.success {
            try? await store.finish(
                id: task.id, state: .done, outputs: result.outputs, backend: backend.name,
                title: title, ownerName: ownerName, bvid: bvid
            )
            // 成功后把链接从 links.txt 里清掉（卫生行为，失败不影响正确性）。
            pendingPrune.insert(task.rawURL)
            pendingPrune.insert(task.taskKey)
            if pendingPrune.count > 500 { pendingPrune = Set(pendingPrune.suffix(300)) }
            Log.success("下载完成：\(display)（\(result.outputs.count) 个文件）")
            await notifier.taskFinished(title: display, outputPaths: result.outputs.map(\.path))
            await publish()
            return true
        }

        let error = result.errorMessage ?? "未知错误"
        if task.attempts >= 3 {
            try? await store.finish(
                id: task.id, state: .failed, error: error, backend: backend.name,
                title: title, ownerName: ownerName, bvid: bvid
            )
            Log.error("下载失败（已放弃）：\(display) — \(error)")
            await notifier.taskFailed(title: display, error: error)
        } else {
            try? await store.retryLater(id: task.id, error: error)
            Log.error("下载失败（将重试）：\(display) — \(error)")
        }
        await publish()
        return false
    }

    private func makeBackend(for url: String) -> any DownloadBackend {
        let downloadDir = AppIdentity.expand(config.downloadDir)
        try? FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
        switch config.backend(for: url) {
        case .yutto:
            return YuttoBackend(
                config: config.yutto, downloadDir: downloadDir,
                timeout: TimeInterval(Self.effectiveTimeout(config))
            )
        case .downie:
            return DownieBackend(config: config.downie, downloadDir: downloadDir)
        }
    }

    /// 设置优先，但保留旧版的环境变量覆盖（`BILI_WATCHER_TIMEOUT`）。
    static func effectiveTimeout(_ config: AppConfig) -> Int {
        if let raw = ProcessInfo.processInfo.environment["BILI_WATCHER_TIMEOUT"], let value = Int(raw), value > 0 {
            return value
        }
        return config.yuttoTimeout
    }

    // MARK: - 删链接

    private func flushPrune() async {
        guard !pendingPrune.isEmpty else {
            snapshot.pendingPruneCount = 0
            await publish()
            return
        }
        snapshot.pendingPruneCount = pendingPrune.count
        guard Date() >= nextPruneAllowedAt else { return }

        let path = await linkSource.path
        let result = await LinkFilePruner.apply(
            path: path,
            consumed: pendingPrune,
            backupDirectory: nil
        )
        if result.applied {
            pendingPrune.removeAll()
            pruneFailures = 0
            snapshot.pruneFailure = nil
            await linkSource.invalidateSignature()
        } else {
            snapshot.pruneFailure = result.reason
            pruneFailures += 1
            Log.debug("链接清理未执行：\(result.reason ?? "未知原因")")
            if pruneFailures >= 3 {
                nextPruneAllowedAt = Date().addingTimeInterval(300)
                pruneFailures = 0
                Log.warning("链接清理连续失败，退避 5 分钟")
            }
        }
        await publish()
    }

    // MARK: - 队列操作

    public func retry(taskID: Int64) async {
        try? await store.requeue(id: taskID)
        tickRequested = true
        await publish()
    }

    public func remove(taskID: Int64) async {
        try? await store.delete(id: taskID)
        await publish()
    }

    public func refreshLinkStatus() async {
        _ = await linkSource.collect()
        let status = await linkSource.status
        snapshot.linkStatusText = status.displayText
        snapshot.linkStatusHealthy = status.isHealthy
        await publish()
    }

    public func linkFilePath() async -> String {
        await linkSource.path
    }

    // MARK: - 快照

    public func refreshSnapshot() async {
        await publish()
    }

    private func publish() async {
        var next = snapshot
        next.isPaused = paused
        next.pendingPruneCount = pendingPrune.count
        next.currentLog = logTail.snapshot
        if let stats = try? await store.stats() { next.stats = stats }
        if let recent = try? await store.recent(limit: 30) { next.recent = recent }
        snapshot = next
        sink?(next)
    }

    // MARK: - 订阅

    /// 订阅轮询有自己的间隔（默认 30 分钟），不跟着 15s 的链接轮询跑。
    private func ingestSubscriptions() async -> Int {
        guard let subscriptionPoller else { return 0 }
        let interval = TimeInterval(max(60, config.subscriptionInterval))
        if let last = lastSubscriptionPoll, Date().timeIntervalSince(last) < interval {
            return 0
        }
        lastSubscriptionPoll = Date()
        return await subscriptionPoller.pollAll()
    }
}