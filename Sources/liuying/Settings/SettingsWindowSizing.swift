import AppKit
import SwiftUI

/// 设置窗口的尺寸策略。
///
/// SwiftUI 的 `Settings` scene 默认按内容尺寸开窗口，且不会自动声明可缩放，
/// 单靠 `.frame(idealWidth:idealHeight:)` 会把窗口锁成固定大小（拖不动、比例发扁）。
/// 这里直接对承载它的 NSWindow 补上：可缩放、最小尺寸、合理默认尺寸，以及跨启动记忆。
struct SettingsWindowSizing: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // makeNSView 时视图还没挂到窗口上，必须等下一个 runloop 才能拿到 NSWindow。
        Task { @MainActor in context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in context.coordinator.attach(to: nsView.window) }
    }

    @MainActor
    final class Coordinator: NSObject {
        static let frameKey = "liuying.settingsWindowFrame"
        static let migratedKey = "liuying.settingsWindowFrameMigrated.v1"
        static let swiftUIFrameKey = "NSWindow Frame com_apple_SwiftUI_Settings_window"
        static let defaultSize = NSSize(width: 620, height: 560)
        static let minSize = NSSize(width: 560, height: 420)
        private static let maxSize = NSSize(width: 100_000, height: 100_000)

        private weak var window: NSWindow?
        private var observing = false
        private var didRestoreFrame = false
        private var reapplyScheduled = false

        func attach(to candidate: NSWindow?) {
            guard let window = candidate else { return }
            if self.window !== window {
                self.window = window
                observing = false
                didRestoreFrame = false
                reapplyScheduled = false
                migrateIfNeeded()
            }

            applySizing(to: window)
            if !didRestoreFrame {
                didRestoreFrame = true
                restoreFrame(window)
            }
            observeIfNeeded(window)

            // SwiftUI 在窗口上屏后仍可能按 scene 默认重设 styleMask / contentMaxSize，
            // 延迟再套一次，避免窗口被锁回固定尺寸。
            if !reapplyScheduled {
                reapplyScheduled = true
                Task { @MainActor [weak self, weak window] in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard let self, let window else { return }
                    self.reapplyScheduled = false
                    self.applySizing(to: window)
                }
            }
        }

        private func migrateIfNeeded() {
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: Self.migratedKey) else { return }
            // 旧版本把「900×508」这类扁窗口记进了 SwiftUI 自己的 frame 自动保存项，
            // 清一次，让新默认尺寸生效；之后由我们自己的 key 记账。
            defaults.removeObject(forKey: Self.swiftUIFrameKey)
            defaults.removeObject(forKey: Self.frameKey)
            defaults.set(true, forKey: Self.migratedKey)
        }

        private func applySizing(to window: NSWindow) {
            if !window.styleMask.contains(.resizable) {
                window.styleMask.insert(.resizable)
            }
            window.minSize = Self.minSize
            window.maxSize = Self.maxSize
            window.contentMinSize = Self.minSize
            window.contentMaxSize = Self.maxSize
        }

        private func restoreFrame(_ window: NSWindow) {
            let defaults = UserDefaults.standard
            if let saved = defaults.string(forKey: Self.frameKey) {
                let frame = NSRectFromString(saved)
                if frame.width >= Self.minSize.width, frame.height >= Self.minSize.height {
                    window.setFrame(frame, display: false)
                }
            } else {
                // 首次运行：以系统给出的位置为中心，换成正常比例的默认尺寸。
                var frame = window.frame
                let center = CGPoint(x: frame.midX, y: frame.midY)
                frame.size = Self.defaultSize
                frame.origin = CGPoint(
                    x: center.x - Self.defaultSize.width / 2,
                    y: center.y - Self.defaultSize.height / 2
                )
                window.setFrame(frame, display: false)
                save(window)
            }
        }

        private func observeIfNeeded(_ window: NSWindow) {
            guard !observing else { return }
            observing = true
            for name in [
                NSWindow.didResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didExposeNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChange(_:)),
                    name: name,
                    object: window
                )
            }
        }

        @objc private func windowDidChange(_ note: Notification) {
            guard let window = note.object as? NSWindow else { return }
            if note.name == NSWindow.didResizeNotification || note.name == NSWindow.didMoveNotification {
                save(window)
            } else {
                // 窗口成为 key / 重新显示时 SwiftUI 可能又按 scene 默认重建窗口约束。
                applySizing(to: window)
            }
        }

        private func save(_ window: NSWindow) {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        }
    }
}
