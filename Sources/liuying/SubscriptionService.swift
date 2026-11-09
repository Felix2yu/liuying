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

    func all() async -> [Subscription] {
        (try? await store.all()) ?? []
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

    func remove(id: Int64) async {
        try? await store.remove(id: id)
    }

    func setEnabled(id: Int64, enabled: Bool) async {
        try? await store.setEnabled(id: id, enabled: enabled)
    }

    func pollNow(subscriptionID: Int64) async {
        _ = await poller.pollNow(subscriptionID: subscriptionID)
    }

    func importRecent(subscriptionID: Int64, count: Int) async {
        _ = await poller.importRecent(subscriptionID: subscriptionID, count: count)
    }
}