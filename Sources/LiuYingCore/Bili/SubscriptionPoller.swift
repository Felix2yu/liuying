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

    /// 手动导入最近 N 条（含首次同步之后想补看的情况）。
    public func importRecent(subscriptionID: Int64, count: Int) async -> Int {
        guard let subscription = try? await store.subscription(id: subscriptionID) else { return 0 }
        do {
            let videos = try await client.latestUploads(mid: subscription.mid)
            let slice = Array(videos.prefix(max(1, count)))
            let added = await enqueue(videos: slice, subscription: subscription)
            if let newest = videos.compactMap(\.created).max() {
                try? await store.recordSuccess(
                    id: subscription.id,
                    watermark: max(newest, subscription.watermark ?? .distantPast),
                    initialSyncDone: true
                )
            }
            return added
        } catch {
            try? await store.recordFailure(
                id: subscription.id, error: error.localizedDescription,
                disable: subscription.consecutiveErrors + 1 >= Self.errorThreshold
            )
            return 0
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
            let added = await enqueue(videos: candidates, subscription: subscription)
            let newest = videos.compactMap(\.created).max()
            try? await store.recordSuccess(
                id: subscription.id,
                watermark: newest.map { max($0, watermark) },
                initialSyncDone: true
            )
            if added > 0 {
                Log.info("订阅 \(subscription.displayName) 捕获 \(added) 条新投稿")
            }
            return PollOutcome(added: added, error: nil, initialSync: false)
        } catch {
            let attempts = subscription.consecutiveErrors + 1
            let disable = attempts >= Self.errorThreshold
            try? await store.recordFailure(
                id: subscription.id, error: error.localizedDescription, disable: disable
            )
            Log.error("订阅 \(subscription.displayName) 轮询失败（第 \(attempts) 次）：\(error.localizedDescription)")
            if disable {
                await notifier.message("订阅「\(subscription.displayName)」连续 \(attempts) 次失败，已自动停用")
            }
            return PollOutcome(added: 0, error: error.localizedDescription, initialSync: false)
        }
    }

    /// 按 bvid 对任务库去重后入队。
    private func enqueue(videos: [BiliVideo], subscription: Subscription) async -> Int {
        var added = 0
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
                    added += 1
                    Log.info("订阅入队：\(video.bvid) \(video.title)")
                }
            } catch {
                Log.warning("订阅入队失败：\(error)")
            }
        }
        return added
    }
}