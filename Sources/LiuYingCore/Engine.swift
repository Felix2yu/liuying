import Foundation

/// 手动添加的结果明细：把「没识别到链接」「全部重复」「入队失败」区分开。
public struct ManualAddResult: Sendable, Equatable {
    public var parsed: Int
    public var added: Int
    public var duplicates: Int
    /// 本次真正插入的任务 id，用于「撤销本次添加」。
    public var addedIDs: [Int64]
    public var failure: String?

    public init(
        parsed: Int = 0, added: Int = 0, duplicates: Int = 0,
        addedIDs: [Int64] = [], failure: String? = nil
    ) {
        self.parsed = parsed
        self.added = added
        self.duplicates = duplicates
        self.addedIDs = addedIDs
        self.failure = failure
    }
}

/// 一次入队的汇总（重复数只用于 UI 反馈，引擎主循环只看 added）。
public struct EnqueueOutcome: Sendable, Equatable {
    public var added: Int
    public var duplicates: Int
    public var addedIDs: [Int64]

    public init(added: Int = 0, duplicates: Int = 0, addedIDs: [Int64] = []) {
        self.added = added
        self.duplicates = duplicates
        self.addedIDs = addedIDs
    }
}

/// 主编排器：轮询 → 去重入队 → 串行下载 → 容器规整 → 删链接 → 通知。
///
/// 串行下载是刻意的（与旧版一致）：并发下载既抢带宽，也更容易触发 B 站风控。
public actor Engine {
    public typealias SnapshotSink = @Sendable (EngineSnapshot) -> Void

    /// 终态落库失败时的补写队列。写失败绝不能被 try? 吞掉：任务会永久停在
    /// downloading（claim 只挑 pending、delete 拒删），只能靠重启恢复。
    private struct StateWrite: Sendable {
        var id: Int64
        var state: TaskState
        var outputs: [TaskOutput]
        var error: String?
        var backend: String?
        var title: String?
        var ownerName: String?
        var bvid: String?
    }

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
    private var pendingStateWrites: [StateWrite] = []
    /// 快照里带多少条历史。默认 30 条够菜单栏用，队列页可逐步加载更多。
    private var recentLimit = 30

    /// 下载成功后待从 links.txt 清掉的 URL / canonical key。
    /// 保序：截断时不能随机丢掉还没清理的键。
    private var pendingPrune: [String] = []
    private var pruneFailures = 0
    private var nextPruneAllowedAt = Date.distantPast

    /// - Parameter biliClient: 由 App 层注入，与订阅轮询器**共用同一个实例**。
    ///   两个独立实例时改 SESSDATA 只会更新引擎里的那个，订阅仍拿旧凭据被 412 风控。
    public init(
        store: TaskStore,
        config: AppConfig,
        notifier: any EngineNotifying = NoopNotifier(),
        subscriptionPoller: SubscriptionPoller? = nil,
        biliClient: BiliClient? = nil
    ) {
        self.store = store
        self.config = config
        self.notifier = notifier
        self.subscriptionPoller = subscriptionPoller
        self.linkSource = ICloudLinkSource(configuredPath: config.watchFile)
        self.biliClient = biliClient ?? BiliClient(sessdata: Self.resolveSessdata(config))
    }

    // MARK: - 配置

    public func updateConfig(_ newConfig: AppConfig) async {
        config = newConfig
        await linkSource.reconfigure(configuredPath: newConfig.watchFile)
        await biliClient.updateSessdata(Self.resolveSessdata(newConfig))
        await subscriptionPoller?.setNotifyEnabled(newConfig.notify)
        // 间隔从 1 小时改成 5 秒不该再等满当前这一轮。
        tickRequested = true
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
        // 立刻发布一次：不发布的话 UI 要等到第一轮跑完才知道引擎已运行。
        Task { await publish() }
        Log.info("引擎启动：轮询 \(max(5, config.pollInterval))s")
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        currentHandle?.cancel()
        snapshot.isRunning = false
        Self.cleanupWorkDirectories()
        Task { await publish() }
        Log.info("引擎已停止")
    }

    /// 强退/终止时 process 的 defer 可能没跑到，work/task-* 会越攒越多。
    private static func cleanupWorkDirectories() {
        let fm = FileManager.default
        let root = AppIdentity.workDirectory
        for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []) where name.hasPrefix("task-") {
            try? fm.removeItem(atPath: (root as NSString).appendingPathComponent(name))
        }
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
        await flushStateWrites()
        do {
            _ = try await ingestOnce()
            if !paused {
                _ = try await processOnce()
            }
            await flushPrune()
            if pendingStateWrites.isEmpty {
                snapshot.lastError = nil
            } else {
                snapshot.lastError = "有 \(pendingStateWrites.count) 个任务状态写入失败，正在重试"
            }
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
        added += try await enqueue(urls: urls, source: .icloud).added

        if config.clipboardMonitor {
            let copied = clipboard.poll()
            if !copied.isEmpty {
                added += try await enqueue(urls: copied, source: .clipboard).added
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
    ) async throws -> EnqueueOutcome {
        guard !urls.isEmpty else { return EnqueueOutcome() }
        var known = try await store.knownKeys()
        var outcome = EnqueueOutcome()
        for url in urls {
            let key = await keyResolver.key(for: url)
            guard !known.contains(key) else {
                outcome.duplicates += 1
                continue
            }
            let video = metadata[key]
            let newTask = NewTask(
                rawURL: url,
                taskKey: key,
                source: source,
                subscriptionID: subscriptionID,
                // bvid 只能是纯 BV/av 号；localKey 会带分 P 后缀，不能喂给 API。
                bvid: video?.bvid ?? CanonicalKey.videoID(in: url),
                title: video?.title,
                pubdate: video?.created
            )
            if let id = try await store.add(newTask) {
                known.insert(key)
                outcome.added += 1
                outcome.addedIDs.append(id)
                Log.info("新链接入队：\(url)（键 \(key)，来源 \(source.displayName)）")
                if config.notify {
                    await notifier.taskAdded(title: video?.title ?? key, url: url)
                }
            } else {
                outcome.duplicates += 1
            }
        }
        return outcome
    }

    /// App 内手动添加：粘贴一整段分享文案也认。
    /// 返回明细而不是一个 Int —— 0 可能是「没识别到」「全部重复」或「写库失败」。
    @discardableResult
    public func addManual(text: String) async -> ManualAddResult {
        let urls = URLExtractor.extract(from: text)
        guard !urls.isEmpty else { return ManualAddResult() }
        do {
            let outcome = try await enqueue(urls: urls, source: .manual)
            await publish()
            return ManualAddResult(
                parsed: urls.count, added: outcome.added, duplicates: outcome.duplicates,
                addedIDs: outcome.addedIDs
            )
        } catch {
            Log.error("手动添加入队失败：\(error)")
            return ManualAddResult(parsed: urls.count, failure: error.localizedDescription)
        }
    }

    /// 撤销一次手动批量添加。已经开始下载的任务不会被抽走。
    /// - Returns: 实际撤销的条数。
    @discardableResult
    public func undoManual(taskIDs: [Int64]) async -> Int {
        guard !taskIDs.isEmpty else { return 0 }
        do {
            let removed = try await store.deletePending(ids: taskIDs)
            await publish()
            return removed
        } catch {
            Log.error("撤销添加失败：\(error)")
            snapshot.lastError = "撤销添加失败：\(error.localizedDescription)"
            await publish()
            return 0
        }
    }

    // MARK: - 下载

    private func processOnce() async throws -> Int {
        var completed = 0
        // 按「处理次数」限流而不是成功次数：失败任务会被放回 pending，
        // 用成功数计数会导致同一条在一轮里被反复 claim。
        let limit = max(1, config.maxTasksPerRound)
        var processed = 0
        while !paused, !Task.isCancelled, processed < limit {
            let claimed = try await store.claim(limit: 1)
            guard let task = claimed.first else { break }
            processed += 1
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
        if let candidate = bvid ?? CanonicalKey.videoID(in: task.rawURL), candidate.hasPrefix("BV") {
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
            // 取消是终态：放回 pending 会让 processOnce 立刻重新 claim，等于「点了取消马上重下」。
            _ = await commit(StateWrite(
                id: task.id, state: .cancelled, outputs: [], error: "已取消",
                backend: backend.name, title: title, ownerName: ownerName, bvid: bvid
            ))
            Log.warning("下载已取消：\(display)")
            await publish()
            return false
        }

        if result.success {
            // Downie 只能确认「已交给它」，落 .sent 等用户确认；不算已完成，也不删链接。
            let state: TaskState = result.handedOff ? .sent : .done
            guard await commit(StateWrite(
                id: task.id, state: state, outputs: result.outputs, error: nil,
                backend: backend.name, title: title, ownerName: ownerName, bvid: bvid
            )) else {
                // 状态没写成，绝不能先删 links.txt 或广播成功通知。
                await publish()
                return false
            }
            if result.handedOff {
                Log.info("已交给 Downie，等待用户确认完成：\(display)")
            } else {
                // 只有「确实来自 links.txt + 后端确认了产出文件」才删行。
                // 手动/剪贴板/订阅任务的 URL 不在文件里；yutto 零产出也没证明下载成功。
                if task.source == .icloud, result.safeToPrune {
                    markPrune(task.rawURL, task.taskKey)
                }
                snapshot.libraryRevision += 1
                Log.success("下载完成：\(display)（\(result.outputs.count) 个文件）")
                if config.notify {
                    await notifier.taskFinished(title: display, outputPaths: result.outputs.map(\.path))
                }
            }
            await publish()
            return true
        }

        let error = result.errorMessage ?? "未知错误"
        if task.attempts >= 3 {
            _ = await commit(StateWrite(
                id: task.id, state: .failed, outputs: [], error: error,
                backend: backend.name, title: title, ownerName: ownerName, bvid: bvid
            ))
            Log.error("下载失败（已放弃）：\(display) — \(error)")
            if config.notify {
                await notifier.taskFailed(title: display, error: error)
            }
        } else {
            do {
                try await store.retryLater(id: task.id, error: error, attempt: task.attempts)
                Log.error("下载失败（将退避重试）：\(display) — \(error)")
            } catch {
                // 连「放回 pending」都写失败，任务会永久停在 downloading；明确标失败让用户能重投。
                Log.error("重试状态写入失败：\(error)")
                _ = await commit(StateWrite(
                    id: task.id, state: .failed, outputs: [], error: "重试状态写入失败：\(error)",
                    backend: backend.name, title: title, ownerName: ownerName, bvid: bvid
                ))
            }
        }
        await publish()
        return false
    }

    /// 终态落库：失败不吞，排进补写队列，直到写成功为止。
    private func commit(_ write: StateWrite) async -> Bool {
        do {
            try await store.finish(
                id: write.id, state: write.state, outputs: write.outputs, error: write.error,
                backend: write.backend, title: write.title, ownerName: write.ownerName, bvid: write.bvid
            )
            return true
        } catch {
            Log.error("任务 \(write.id) 状态写入失败：\(error)")
            snapshot.lastError = "任务状态写入失败：\(error)，下一轮会重试"
            pendingStateWrites.append(write)
            return false
        }
    }

    private func flushStateWrites() async {
        guard !pendingStateWrites.isEmpty else { return }
        var remaining: [StateWrite] = []
        for write in pendingStateWrites {
            do {
                try await store.finish(
                    id: write.id, state: write.state, outputs: write.outputs, error: write.error,
                    backend: write.backend, title: write.title, ownerName: write.ownerName, bvid: write.bvid
                )
                if write.state == .done || write.state == .sent { snapshot.libraryRevision += 1 }
            } catch {
                remaining.append(write)
            }
        }
        pendingStateWrites = remaining
        if remaining.isEmpty {
            Log.info("任务状态补写完成")
        } else {
            Log.warning("仍有 \(remaining.count) 个任务状态写入失败，继续重试")
        }
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

    /// 记录待清理的键；保序插入，超限时截断最旧的一段而不是随机丢键。
    private func markPrune(_ rawURL: String, _ taskKey: String) {
        for value in [rawURL, taskKey] where !pendingPrune.contains(value) {
            pendingPrune.append(value)
        }
        if pendingPrune.count > 500 {
            pendingPrune = Array(pendingPrune.suffix(300))
        }
    }

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
            consumed: Set(pendingPrune),
            backupDirectory: AppIdentity.backupsDirectory
        )
        if result.applied || result.nothingMatched {
            // 「文件里本来就没有这些链接」不是失败：清掉待清理键，避免菜单栏常驻报错
            // 并连续 3 次后退避 5 分钟，把真正的清理也一起拖住。
            pendingPrune.removeAll()
            pruneFailures = 0
            snapshot.pruneFailure = nil
            if result.applied {
                await linkSource.invalidateSignature()
            }
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

    /// Downie 任务：用户确认文件确实下载完后，sent → done。
    /// 确认之前不删 links.txt，也不计入已完成；确认后视频库会自动刷新。
    public func confirm(taskID: Int64) async {
        guard let task = try? await store.task(id: taskID) else { return }
        guard await commit(StateWrite(
            id: taskID, state: .done, outputs: task.outputs, error: nil,
            backend: task.backend, title: task.title, ownerName: task.ownerName, bvid: task.bvid
        )) else {
            await publish()
            return
        }
        if task.source == .icloud { markPrune(task.rawURL, task.taskKey) }
        snapshot.libraryRevision += 1
        tickRequested = true
        Log.info("已确认完成：\(task.displayTitle)")
        if config.notify {
            await notifier.taskFinished(title: task.displayTitle, outputPaths: task.outputs.map(\.path))
        }
        await publish()
    }

    public func remove(taskID: Int64) async {
        try? await store.delete(id: taskID)
        await publish()
    }

    public func refreshLinkStatus() async {
        // collect() 会提交文件签名，返回值绝不能丢：启动时这个方法与主循环并行跑，
        // 旧实现把采到的链接直接扔掉，签名却已更新 → 那些链接再也不会被采集。
        let urls = await linkSource.collect()
        if !urls.isEmpty {
            do {
                _ = try await enqueue(urls: urls, source: .icloud)
            } catch {
                Log.error("刷新链接状态时入队失败：\(error)")
            }
        }
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

    /// 队列页「加载更多历史」：抬高快照上限，让旧任务／旧失败也可管理。
    public func showMoreHistory() async {
        recentLimit = min(recentLimit + 50, 1_000)
        await publish()
    }

    private func publish() async {
        var next = snapshot
        next.isPaused = paused
        next.pendingPruneCount = pendingPrune.count
        next.currentLog = logTail.snapshot
        if let stats = try? await store.stats() { next.stats = stats }
        // 多查一条判断是否还有更旧记录，避免「刚好取满」被误判成还有更多。
        if let recent = try? await store.recent(limit: recentLimit + 1) {
            next.recentTruncated = recent.count > recentLimit
            next.recent = Array(recent.prefix(recentLimit))
        }
        next.recentLimit = recentLimit
        // next 只是一次性投影，绝不能写回 snapshot：
        // publish 会在 store.stats()/recent() 上挂起，期间 start()、runRound()、
        // finish() 等会直接改 snapshot（isRunning / lastRoundAt / libraryRevision…）；
        // 写回旧拷贝会把这些改动全部抹掉（实机表现为引擎明明在轮询，菜单却显示「引擎未运行」）。
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