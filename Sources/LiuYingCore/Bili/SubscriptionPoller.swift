import Foundation

/// UP 主订阅轮询。
///
/// 两条硬规则：
///  1. **首次同步绝不灌历史**：只把水位设到最新一条的发布时间并入队 0 条，
///     否则一加订阅就会把几百个旧视频全下下来。
///  2. **连续 3 次失败自动停用**（照搬 bili-history 的熔断），避免风控期间无限重试。
public actor SubscriptionPoller {
    public struct PollOutcome: Sendable, Equatable {
        public var added: Int
        public var error: String?
        public var initialSync: Bool
    }

    private let store: SubscriptionStore
    private let taskStore: TaskStore
    private let client: BiliClient
    private let notifier: any EngineNotifying
    private var notifyEnabled = true
    static let errorThreshold = 3

    public init(
        store: SubscriptionStore,
        taskStore: TaskStore,
        client: BiliClient,
        notifier: any EngineNotifying = NoopNotifier()
    ) {
        self.store = store
        self.taskStore = taskStore
        self.client = client
        self.notifier = notifier
    }

    /// 由 Engine.updateConfig 转发「发送通知」开关，保证订阅熔断提示也受控。
    public func setNotifyEnabled(_ enabled: Bool) {
        notifyEnabled = enabled
    }

    /// 轮询所有启用的订阅，返回新入队总数。
    public func pollAll() async -> Int {
        guard let subscriptions = try? await store.all() else { return 0 }
        var added = 0
        for subscription in subscriptions where subscription.enabled {
            added += await poll(subscription).added
        }
        return added
    }

    public func pollNow(subscriptionID: Int64) async -> PollOutcome {
        guard let subscription = try? await store.subscription(id: subscriptionID) else {
            return PollOutcome(added: 0, error: "订阅不存在", initialSync: false)
        }
        return await poll(subscription)
    }

    /// 手动导入最近 N 条（含首次同步之后想补看的情况）。保留 Int 版本给既有调用方。
    public func importRecent(subscriptionID: Int64, count: Int) async -> Int {
        await importRecentOutcome(subscriptionID: subscriptionID, count: count).added
    }

    /// 带错误信息的版本：UI 不能再把 412 风控显示成「什么都没发生」。
    public func importRecentOutcome(subscriptionID: Int64, count: Int) async -> PollOutcome {
        guard let subscription = try? await store.subscription(id: subscriptionID) else {
            return PollOutcome(added: 0, error: "订阅不存在", initialSync: false)
        }
        do {
            let videos = try await client.latestUploads(mid: subscription.mid)
            let slice = Array(videos.prefix(max(1, count)))
            let outcome = await enqueue(videos: slice, subscription: subscription)
            // 水位只推进到「本次真正处理过」的最新一条。旧实现用整页最新时间推进，
            // 会把第 6~49 条永久挡在增量轮询之外。
            try? await store.recordSuccess(
                id: subscription.id,
                watermark: outcome.newestHandled.map {
                    max($0, subscription.watermark ?? .distantPast)
                },
                initialSyncDone: true
            )
            return PollOutcome(added: outcome.added, error: nil, initialSync: false)
        } catch {
            let attempts = subscription.consecutiveErrors + 1
            try? await store.recordFailure(
                id: subscription.id, error: error.localizedDescription,
                disable: attempts >= Self.errorThreshold
            )
            Log.error("订阅 \(subscription.displayName) 导入失败：\(error.localizedDescription)")
            return PollOutcome(added: 0, error: error.localizedDescription, initialSync: false)
        }
    }

    private func poll(_ subscription: Subscription) async -> PollOutcome {
        do {
            let videos = try await client.latestUploads(mid: subscription.mid)

            // 顺手把 UP 主名字补上（view 返回 owner.name）。
            if subscription.name == nil, let bvid = videos.first?.bvid, !bvid.isEmpty,
               let detail = try? await client.view(bvid: bvid), let name = detail.ownerName,
               !name.isEmpty {
                try? await store.updateName(id: subscription.id, name: name)
            }

            if !subscription.initialSyncDone {
                let newest = videos.compactMap(\.created).max()
                try? await store.recordSuccess(
                    id: subscription.id, watermark: newest, initialSyncDone: true
                )
                Log.info("订阅 \(subscription.displayName) 首次同步完成，水位 \(newest.map(String.init(describing:)) ?? "无")，不入队历史")
                return PollOutcome(added: 0, error: nil, initialSync: true)
            }

            let watermark = subscription.watermark ?? .distantPast
            let candidates = videos.filter { video in
                guard let created = video.created else { return false }
                return created > watermark
            }
            let outcome = await enqueue(videos: candidates, subscription: subscription)
            // 只推进到成功落库/已存在的最新一条；入队失败的视频留在水位之前，下轮还能补。
            try? await store.recordSuccess(
                id: subscription.id,
                watermark: outcome.newestHandled.map { max($0, watermark) },
                initialSyncDone: true
            )
            if outcome.added > 0 {
                Log.info("订阅 \(subscription.displayName) 捕获 \(outcome.added) 条新投稿")
            }
            return PollOutcome(added: outcome.added, error: nil, initialSync: false)
        } catch {
            let attempts = subscription.consecutiveErrors + 1
            let disable = attempts >= Self.errorThreshold
            try? await store.recordFailure(
                id: subscription.id, error: error.localizedDescription, disable: disable
            )
            Log.error("订阅 \(subscription.displayName) 轮询失败（第 \(attempts) 次）：\(error.localizedDescription)")
            if disable, notifyEnabled {
                await notifier.message("订阅「\(subscription.displayName)」连续 \(attempts) 次失败，已自动停用")
            }
            return PollOutcome(added: 0, error: error.localizedDescription, initialSync: false)
        }
    }

    /// 一次入队的汇总。newestHandled 只包含「确实落库或本来就已存在」的稿件，
    /// 写入失败的不计入，否则水位会跳过它们造成永久漏抓。
    private struct EnqueueSummary {
        var added = 0
        var newestHandled: Date?
    }

    /// 按 bvid 对任务库去重后入队。
    private func enqueue(videos: [BiliVideo], subscription: Subscription) async -> EnqueueSummary {
        var summary = EnqueueSummary()
        for video in videos {
            let task = NewTask(
                rawURL: video.pageURL,
                taskKey: video.bvid,
                source: .subscription,
                subscriptionID: subscription.id,
                bvid: video.bvid,
                title: video.title,
                ownerName: subscription.name,
                ownerMid: subscription.mid,
                pubdate: video.created
            )
            do {
                if try await taskStore.add(task) != nil {
                    summary.added += 1
                    Log.info("订阅入队：\(video.bvid) \(video.title)")
                }
                // 已存在同样算「已处理」，水位可以推过它。
                if let created = video.created {
                    let current = summary.newestHandled ?? created
                    summary.newestHandled = max(current, created)
                }
            } catch {
                Log.warning("订阅入队失败：\(error)")
            }
        }
        return summary
    }
}