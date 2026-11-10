import AppKit
import LiuYingCore

/// 「在 Dock 中显示」偏好：菜单栏应用默认 .accessory，开启后常驻 .regular。
/// 这样即使系统隐藏了菜单栏图标，App 仍可从 Dock 与主菜单进入。
enum DockVisibility {
    static let key = "show_dock_icon"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// 应用生命周期：激活策略切换、睡眠唤醒补跑、Dock 图标管理。
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用的常态：不占 Dock。用户显式开启 Dock 显示时保持 .regular。
        NSApp.setActivationPolicy(DockVisibility.isEnabled ? .regular : .accessory)
        // Info.plist 开了 NSSupportsSuddenTermination；常驻轮询 + 子进程场景下必须禁用，
        // 否则系统可以在不调用 applicationShouldTerminate 的情况下直接杀掉进程。
        ProcessInfo.processInfo.disableSuddenTermination()

        // 睡眠期间轮询停摆，醒来立刻补跑一轮。
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Log.info("系统唤醒，立刻补跑一轮")
            Task { @MainActor in
                await AppEnvironment.shared.engine?.tickNow()
            }
        }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // 等一个 runloop 回合再判断，否则窗口还没从 NSApp.windows 里移除。
                try? await Task.sleep(nanoseconds: 80_000_000)
                let hasVisible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if !hasVisible, !DockVisibility.isEnabled {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        Task { @MainActor in
            await AppEnvironment.shared.bootstrap()
            await Notifier.shared.requestAuthorizationIfNeeded()
        }
    }

    /// 用户可能在系统设置里改了开机启动／通知权限，切回 App 时同步一次。
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AppEnvironment.shared.loginItem.refresh()
            await Notifier.shared.refreshAuthorization()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowRouter.shared.request(.library(focus: nil))
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// 允许系统恢复窗口位置与尺寸（HIG Windows）。
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// 终止前先停引擎并等子进程退出：直接退出会留下孤儿 yutto 进程、
    /// downloading 状态的任务行和 work/task-* 临时目录。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard AppEnvironment.shared.engine != nil else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            await AppEnvironment.shared.stopEngine()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }
}
