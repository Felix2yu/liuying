import AppKit
import LiuYingCore

/// 应用生命周期：激活策略切换、睡眠唤醒补跑、Dock 图标管理。
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用的常态：不占 Dock。
        NSApp.setActivationPolicy(.accessory)

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
                if !hasVisible {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        Task { @MainActor in
            await AppEnvironment.shared.bootstrap()
            await Notifier.shared.requestAuthorizationIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowRouter.shared.request(.library(focus: nil))
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }
}