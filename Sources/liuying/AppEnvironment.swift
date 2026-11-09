import Foundation
import Observation
import LiuYingCore
import SwiftUI

/// 主窗口的路由请求。菜单栏 label 常驻，观察 token 变化后替其它代码开窗
/// （AppDelegate、通知点击都没有 SwiftUI 的 openWindow 环境）。
@MainActor
@Observable
final class WindowRouter {
    enum Route: Equatable {
        case library(focus: String?)
        case queue
        case subscriptions
        case addLink
    }

    static let shared = WindowRouter()

    private(set) var token = 0
    private(set) var pendingRoute: Route?

    private init() {}

    func request(_ route: Route) {
        pendingRoute = route
        token += 1
    }

    func consume() -> Route? {
        defer { pendingRoute = nil }
        return pendingRoute
    }
}

/// 全局依赖容器。App 与菜单栏共享同一份。
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let configStore: ConfigStore
    let model = EngineModel()
    private(set) var taskStore: TaskStore?
    private(set) var engine: Engine?
    private(set) var subscriptions: SubscriptionService?
    var startupError: String?
    var isBootstrapped = false

    private init() {
        self.configStore = ConfigStore()
    }

    func bootstrap() async {
        guard !isBootstrapped else { return }
        do {
            try AppIdentity.ensureDirectories()
            let store = try TaskStore()
            let recovered = try await store.recoverInterrupted()
            if recovered > 0 { Log.warning("上次有 \(recovered) 个任务被中断，已重新排队") }

            let subscriptionStore = SubscriptionStore(database: store.database)
            let poller = SubscriptionPoller(
                store: subscriptionStore,
                taskStore: store,
                client: BiliClient(sessdata: Engine.resolveSessdata(configStore.config)),
                notifier: NotificationBridge()
            )

            let engine = Engine(
                store: store,
                config: configStore.config,
                notifier: NotificationBridge(),
                subscriptionPoller: poller
            )
            let model = self.model
            await engine.setSnapshotSink { snapshot in
                Task { @MainActor in model.apply(snapshot) }
            }
            await engine.refreshSnapshot()

            // 直接开跑：旧服务已经退役，不存在抢同一批链接的问题。
            // 引导页只是信息性的，关掉与否都不该影响轮询。
            await engine.start()

            // 无论如何先读一次链接文件：日志里能直接看到实际监听的路径与可读性。
            // 不阻塞启动 —— iCloud 占位符首次读取可能要等云端下发。
            Task {
                await engine.refreshLinkStatus()
                let linkPath = await engine.linkFilePath()
                Log.info("监听链接文件：\(linkPath)")
            }

            self.taskStore = store
            self.engine = engine
            self.subscriptions = SubscriptionService(store: subscriptionStore, poller: poller)
            self.isBootstrapped = true
            Log.info("\(AppIdentity.displayName) 启动完成")
        } catch {
            startupError = error.localizedDescription
            Log.error("启动失败：\(error)")
        }
    }

    func stopEngine() async {
        await engine?.stop()
    }

    /// 配置改动后同步给引擎（轮询间隔、路径、yutto 参数都要立刻生效）。
    func pushConfigToEngine() async {
        guard let engine else { return }
        await engine.updateConfig(configStore.config)
        await engine.refreshSnapshot()
    }

    func setNotifierAuthorized() async {
        await Notifier.shared.requestAuthorizationIfNeeded()
    }
}