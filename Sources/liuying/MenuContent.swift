import AppKit
import LiuYingCore
import SwiftUI

/// 菜单栏下拉菜单。
struct MenuContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    private var snapshot: EngineSnapshot { env.model.snapshot }

    var body: some View {
        Text(snapshot.statusLine)

        if let last = snapshot.lastRoundAt {
            Text("上次检查 \(Self.timeFormatter.string(from: last))")
        }
        if let error = snapshot.lastError {
            Text("错误：\(error)")
        }
        if let pruneFailure = snapshot.pruneFailure {
            Text("链接清理：\(pruneFailure)")
        }

        Divider()

        Button("打开\(AppIdentity.displayName)…") { openWindow(.library(focus: nil)) }
            .keyboardShortcut("o")
        Button("添加链接…") { openWindow(.addLink) }
        Button("立即检查") { Task { await env.engine?.tickNow() } }

        if snapshot.isPaused {
            Button("继续轮询") { Task { await env.engine?.resume() } }
        } else {
            Button("暂停轮询") { Task { await env.engine?.pause() } }
        }

        if snapshot.downloadingCount > 0 {
            Button("取消当前下载") { Task { await env.engine?.cancelCurrentDownload() } }
        }

        Divider()

        ForEach(snapshot.recent.filter { $0.state == .done }.prefix(3)) { task in
            Button("✓ \(task.displayTitle)") {
                openWindow(.library(focus: task.title))
            }
        }

        if snapshot.recent.filter({ $0.state == .done }).isEmpty {
            Text("还没有下载记录")
        }

        Divider()

        Button("设置…") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Toggle("登录时启动", isOn: Binding(
            get: { launchAtLogin },
            set: { newValue in
                if let error = LoginItem.setEnabled(newValue) {
                    loginError = error
                    return
                }
                launchAtLogin = newValue
            }
        ))

        if let loginError {
            Text(loginError)
        }

        Divider()

        Button("退出\(AppIdentity.displayName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openWindow(_ route: WindowRouter.Route) {
        WindowRouter.shared.request(route)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}