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

        Window(AppIdentity.displayName, id: "main") {
            MainWindow()
                .environment(env)
                .task { await env.bootstrap() }
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(env)
        }
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
            .task(id: WindowRouter.shared.token) {
                guard let route = WindowRouter.shared.consume() else { return }
                openWindow(id: "main")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                apply(route)
            }
    }

    private var symbol: String {
        if snapshot.isPaused { return "pause.circle" }
        if snapshot.downloadingCount > 0 { return "arrow.down.circle.fill" }
        if snapshot.pendingCount > 0 { return "tray.full" }
        return "play.rectangle.on.rectangle"
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