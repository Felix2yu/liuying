import AppKit
import LiuYingCore
import SwiftUI

@main
struct LiuyingApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @State private var env = AppEnvironment.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(env)
        } label: {
            MenuBarLabel()
                .environment(env)
        }
        .menuBarExtraStyle(.menu)

        // 窗口标题用内容区名称，不用 App 名（HIG Toolbars > Titles）。
        Window("视频库", id: "main") {
            MainWindow()
                .environment(env)
                .task { await env.bootstrap() }
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            // 本 App 不创建文档：把 File > New（⌘N）让给「添加链接…」。
            // ⌘O 保留系统 Open 语义，不再借用；主窗口由「显示」组与 Dock 重开进入。
            CommandGroup(replacing: .newItem) {
                Button("添加链接…") {
                    WindowRouter.shared.request(.addLink)
                }
                .keyboardShortcut("n")
            }
            // 追加到系统 View 菜单的工具栏组之后，为三个区域提供键盘导航。
            CommandGroup(after: .toolbar) {
                Button("视频库") { MainWindowState.shared.selectedTab = .library }
                    .keyboardShortcut("1")
                Button("队列") { MainWindowState.shared.selectedTab = .queue }
                    .keyboardShortcut("2")
                Button("订阅") { MainWindowState.shared.selectedTab = .subscriptions }
                    .keyboardShortcut("3")
                Divider()
                Button("显示主窗口") {
                    WindowRouter.shared.request(.library(focus: nil))
                }
                Button("立即检查") {
                    Task { await AppEnvironment.shared.engine?.tickNow() }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(env)
        }
        .defaultSize(width: 620, height: 560)
        .windowResizability(.contentMinSize)
    }
}

/// 常驻的菜单栏图标。同时承担「替别人开窗」的职责：
/// AppDelegate 与通知点击拿不到 SwiftUI 的 openWindow 环境，只能靠这里兜住。
struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    private var snapshot: EngineSnapshot { env.model.snapshot }

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(Text(AppIdentity.displayName + " 状态"))
            .accessibilityValue(Text(statusText))
            .accessibilityAddTraits(.isButton)
            .task(id: WindowRouter.shared.token) {
                guard let route = WindowRouter.shared.consume() else { return }
                openWindow(id: "main")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                apply(route)
            }
    }

    /// 统一使用无填充的 SF Symbol 轮廓，避免 fill / outline 混用让菜单栏图标风格跳变。
    /// 具体状态由无障碍文案表达，不再靠图标形状差异传达。
    private var symbol: String {
        if snapshot.isPaused { return "pause.circle" }
        if snapshot.downloadingCount > 0 { return "arrow.down.circle" }
        if snapshot.pendingCount > 0 { return "tray" }
        return "play.rectangle.on.rectangle"
    }

    private var statusText: String {
        if snapshot.isPaused { return "已暂停轮询" }
        if snapshot.downloadingCount > 0 { return "下载中，\(snapshot.downloadingCount) 个任务" }
        if snapshot.pendingCount > 0 { return "待处理 \(snapshot.pendingCount) 个任务" }
        return "空闲"
    }

    private func apply(_ route: WindowRouter.Route) {
        switch route {
        case .library(let focus):
            MainWindowState.shared.selectedTab = .library
            MainWindowState.shared.focusID = focus
        case .queue:
            MainWindowState.shared.selectedTab = .queue
        case .subscriptions:
            MainWindowState.shared.selectedTab = .subscriptions
        case .addLink:
            MainWindowState.shared.showAddLink = true
        }
    }
}

/// 主窗口的跨进程内共享 UI 状态（打开哪个 tab、聚焦哪一行）。
@MainActor
@Observable
final class MainWindowState {
    enum Tab: String, CaseIterable, Identifiable {
        case library
        case queue
        case subscriptions

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .library: "视频库"
            case .queue: "队列"
            case .subscriptions: "订阅"
            }
        }
    }

    static let shared = MainWindowState()

    var selectedTab: Tab = .library
    var focusID: String?
    var showAddLink = false
    var searchText = ""

    private init() {}
}
