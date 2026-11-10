import AppKit
import LiuYingCore
import SwiftUI

/// 菜单栏下拉菜单。
struct MenuContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings

    private var snapshot: EngineSnapshot { env.model.snapshot }

    /// 引擎还没起来时，命令不该静默无反应。
    private var engineReady: Bool { env.engine != nil && env.startupError == nil }

    private var recentDone: [DownloadTask] {
        Array(snapshot.recent.filter { $0.state == .done }.prefix(3))
    }

    var body: some View {
        Text(snapshot.statusLine)

        if let error = env.startupError {
            Text("启动失败：\(error)")
        } else if !engineReady {
            Text("引擎正在启动…")
        } else if !snapshot.isRunning {
            Text("引擎未运行")
        } else if let last = snapshot.lastRoundAt {
            // 使用系统格式化器，尊重用户的 12/24 小时制与区域设置。
            Text("上次检查 \(last.formatted(date: .omitted, time: .standard))")
        }
        if let error = snapshot.lastError {
            Text("错误：\(error)")
        }
        if let pruneFailure = snapshot.pruneFailure {
            Text("链接清理：\(pruneFailure)")
        }

        Divider()

        Button("显示主窗口") { openWindow(.library(focus: nil)) }
        Button("添加链接…") { openWindow(.addLink) }
            .disabled(!engineReady)
        Button("立即检查") { Task { await env.engine?.tickNow() } }
            .disabled(!engineReady)

        // 可变标签的对立命令符合 HIG Menus > Toggled items。
        if snapshot.isPaused {
            Button("继续轮询") { Task { await env.engine?.resume() } }
                .disabled(!engineReady)
        } else {
            Button("暂停轮询") { Task { await env.engine?.pause() } }
                .disabled(!engineReady)
        }

        // 命令项常驻，不可用时置灰而不是隐藏（HIG The menu bar）。
        Button("取消当前下载") { Task { await env.engine?.cancelCurrentDownload() } }
            .disabled(!engineReady || snapshot.downloadingCount == 0)

        Divider()

        if recentDone.isEmpty {
            Text("还没有下载记录")
        } else {
            Text("最近完成")
            ForEach(recentDone) { task in
                Button(task.displayTitle) {
                    // 优先用任务实际产出文件路径做深链，比拿标题去库里猜文件名准得多；
                    // 没有产出时退回去重键，由视频库按标题/BV 号反查。
                    openWindow(.library(focus: task.outputs.first?.path ?? task.taskKey))
                }
            }
        }

        Divider()

        // 标准 ⌘, 由 Settings scene 提供；弹出菜单里不重复注册无效快捷键。
        Button("设置…") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Toggle("登录时启动", isOn: Binding(
            get: { env.loginItem.isEnabled },
            set: { _ = env.loginItem.set($0) }
        ))

        if let loginError = env.loginItem.errorMessage {
            Text(loginError)
        }

        Divider()

        // 标准 ⌘Q 由 App 菜单提供；MenuBarExtra 弹出菜单里的快捷键不会分发。
        Button("退出\(AppIdentity.displayName)") { NSApp.terminate(nil) }
    }

    private func openWindow(_ route: WindowRouter.Route) {
        WindowRouter.shared.request(route)
    }
}
