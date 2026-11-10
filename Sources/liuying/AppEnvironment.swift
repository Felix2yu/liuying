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

/// 登录项状态的唯一可观察来源。
/// 菜单、设置、引导页以前各持一份 @State，一边改了另一边不知道，系统侧改动也不会刷新。
@MainActor
@Observable
final class LoginItemState {
    private(set) var isEnabled: Bool
    private(set) var statusText: String
    var errorMessage: String?

    init() {
        isEnabled = LoginItem.isEnabled
        statusText = LoginItem.statusText
    }

    func refresh() {
        isEnabled = LoginItem.isEnabled
        statusText = LoginItem.statusText
    }

    /// - Returns: 是否设置成功；失败时 errorMessage 给用户看。
    @discardableResult
    func set(_ enabled: Bool) -> Bool {
        if let error = LoginItem.setEnabled(enabled) {
            errorMessage = error
            refresh()
            return false
        }
        errorMessage = nil
        refresh()
        return true
    }
}

/// 全局依赖容器。App 与菜单栏共享同一份。
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let configStore: ConfigStore
    let model = EngineModel()
    let loginItem = LoginItemState()
    private(set) var taskStore: TaskStore?
    private(set) var engine: Engine?
    private(set) var subscriptions: SubscriptionService?
    var startupError: String?
    var isBootstrapped = false
    /// bootstrap 只允许真正跑一次。用保存的 Task 串行化并发调用，避免起两个 Engine。
    private var bootstrapTask: Task<Void, Never>?

    private init() {
        self.configStore = ConfigStore()
    }

    /// 两个入口（AppDelegate 的 applicationDidFinishLaunching 与主窗口 .task）都会调，
    /// 必须在任何 await 之前占位，否则两边同时通过 guard，会起两个 Engine。
    func bootstrap() async {
        if let existing = bootstrapTask {
            await existing.value
            return
        }
        let task = Task { await self.performBootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        guard !isBootstrapped else { return }
        do {
            try AppIdentity.ensureDirectories()
            let store = try TaskStore()
            let recovered = try await store.recoverInterrupted()
            if recovered > 0 { Log.warning("上次有 \(recovered) 个任务被中断，已重新排队") }

            let subscriptionStore = SubscriptionStore(database: store.database)
            // 引擎与订阅轮询器必须共用同一个 client：两个实例时改 SESSDATA 只更新其中一个，
            // 订阅仍拿旧凭据请求，被 412 风控后累计失败熔断。
            let sharedBiliClient = BiliClient(sessdata: Engine.resolveSessdata(configStore.config))
            let poller = SubscriptionPoller(
                store: subscriptionStore,
                taskStore: store,
                client: sharedBiliClient,
                notifier: NotificationBridge()
            )
            // 初始配置也要同步：Engine 自己读 config.notify，但 poller 是独立实例。
            await poller.setNotifyEnabled(configStore.config.notify)

            let engine = Engine(
                store: store,
                config: configStore.config,
                notifier: NotificationBridge(),
                subscriptionPoller: poller,
                biliClient: sharedBiliClient
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
            // 允许后续入口重试，而不是永远卡在失败的 bootstrapTask 上。
            bootstrapTask = nil
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

    /// 恢复默认设置并立刻同步给引擎。调用方负责先弹确认框。
    func resetConfig() async {
        configStore.resetToDefaults()
        await pushConfigToEngine()
    }
}