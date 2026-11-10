import Foundation
import LiuYingCore
import Observation

/// 订阅的 UI 门面：列表/增删/立即刷新都走这里，避免界面直接拼底层 actor。
@MainActor
@Observable
final class SubscriptionService {
    private let store: SubscriptionStore
    private let poller: SubscriptionPoller

    init(store: SubscriptionStore, poller: SubscriptionPoller) {
        self.store = store
        self.poller = poller
    }

    func all() async throws -> [Subscription] {
        try await store.all()
    }

    /// - Returns: nil 表示成功，否则是给用户看的错误文案。
    func add(mid: Int64) async -> String? {
        do {
            guard let id = try await store.add(mid: mid, name: nil) else {
                return "这个 UID 已经订阅过了"
            }
            // 立刻做一次首次同步：记下水位、补上 UP 主名字，但不会入队历史投稿。
            let outcome = await poller.pollNow(subscriptionID: id)
            if let error = outcome.error {
                return "订阅已添加，但首次同步失败：\(error)"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// - Returns: nil 表示成功，否则是给用户看的错误文案。
    func remove(id: Int64) async -> String? {
        do {
            try await store.remove(id: id)
            return nil
        } catch {
            return "删除失败：\(error.localizedDescription)"
        }
    }

    func setEnabled(id: Int64, enabled: Bool) async -> String? {
        do {
            try await store.setEnabled(id: id, enabled: enabled)
            return nil
        } catch {
            return "切换启用状态失败：\(error.localizedDescription)"
        }
    }

    /// 返回完整结果，UI 才能显示「新增 N 条」或 412 风控错误，而不是毫无反应。
    func pollNow(subscriptionID: Int64) async -> SubscriptionPoller.PollOutcome? {
        await poller.pollNow(subscriptionID: subscriptionID)
    }

    func importRecent(subscriptionID: Int64, count: Int) async -> SubscriptionPoller.PollOutcome? {
        await poller.importRecentOutcome(subscriptionID: subscriptionID, count: count)
    }
}