import AppKit
import LiuYingCore
import SwiftUI

// MARK: - 主窗口标记

/// SwiftUI 的 `Window(id: "main")` 不会把 id 写到 `NSWindow.identifier`。
/// 这里显式打标，⌘V 监听据此区分主窗口与设置窗口／其它面板。
final class MainWindowTagView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("liuying.main")

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = Self.identifier
    }

    /// 标记 view 铺在主窗口背景里，绝不能吞掉鼠标事件。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MainWindowTag: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowTagView {
        MainWindowTagView(frame: .zero)
    }

    func updateNSView(_ nsView: MainWindowTagView, context: Context) {}
}

// MARK: - 轻量反馈

/// ⌘V 与导入共用的非模态提示。不弹窗、不抢焦点，几秒后自动消失。
@MainActor
@Observable
final class FeedbackCenter {
    private(set) var message: String?
    private(set) var undoIDs: [Int64] = []
    private(set) var revision = 0

    func show(_ text: String, undoIDs: [Int64] = []) {
        message = text
        self.undoIDs = undoIDs
        revision += 1
        let expected = revision
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.revision == expected else { return }
            self.message = nil
            self.undoIDs = []
        }
    }

    func dismiss() {
        revision += 1
        message = nil
        undoIDs = []
    }
}

// MARK: - ⌘V 监听

/// 从 NSEvent 拆出来的 Sendable 标量，供 @MainActor 侧判定。
private struct KeyEventInfo: Sendable {
    var modifierFlags: UInt
    var characters: String
    var isRepeat: Bool
}

/// 复刻 Downie 自己的交互：「主窗口处于活动状态时按 ⌘V 加载剪贴板里的链接」。
///
/// 用 local monitor 而不是替换系统 Paste 菜单项：后者会把 `paste:` 动作从第一响应者
/// 手里抢走，输入框就粘不进东西了。这里只在**所有条件都满足**时消费事件，其余情况原样返回。
@MainActor
final class PasteShortcutController {
    static let shared = PasteShortcutController()

    private var monitor: Any?
    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // NSEvent 不是 Sendable，不能跨 isolation 边界传进 @MainActor 闭包。
            // 先在事件回调里拆成标量，isolated 侧只回一个 Bool（是否消费），
            // 最终要不要把原事件交回系统由这里决定。
            let info = KeyEventInfo(
                modifierFlags: event.modifierFlags.rawValue,
                characters: event.charactersIgnoringModifiers ?? "",
                isRepeat: event.isARepeat
            )
            let consume = MainActor.assumeIsolated {
                PasteShortcutController.shared.handle(info)
            }
            return consume ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// - Returns: 是否消费这个事件（true 表示不再交给系统粘贴）。
    private func handle(_ info: KeyEventInfo) -> Bool {
        guard PasteShortcut.isPlainCommandV(
            modifierFlags: info.modifierFlags, characters: info.characters
        ) else { return false }
        let env = AppEnvironment.shared
        let keyWindow = NSApp.keyWindow
        let isMainWindowKey = Self.isMainWindow(keyWindow)
        let hasSheet = keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil
        let isTextEditing = Self.isEditableResponder(keyWindow?.firstResponder)
        let clipboard = PasteboardText.read()

        let decision = PasteShortcut.evaluate(
            isEnabled: env.configStore.config.pasteShortcut,
            isAppActive: NSApp.isActive,
            isMainWindowKey: isMainWindowKey,
            hasSheet: hasSheet,
            isTextEditing: isTextEditing,
            clipboardText: clipboard
        )

        switch decision {
        case .passthrough(let reason):
            // 只有「按了 ⌘V 但剪贴板没内容/没链接」才提示；正常粘贴路径一声不吭。
            if !info.isRepeat, let notice = reason.notice {
                Log.info("⌘V 未触发下载：\(reason.rawValue)")
                env.feedback.show(notice)
            }
            return false

        case .download(let urls):
            // 按住不放产生的重复事件只吞掉，不重复入队。
            guard !info.isRepeat else { return true }
            Log.info("⌘V 触发下载：\(urls.count) 条链接")
            env.feedback.show("正在添加剪贴板里的链接…")
            let text = clipboard
            Task { @MainActor in
                guard let engine = env.engine else {
                    env.feedback.show("引擎还没启动完成")
                    return
                }
                let outcome = await engine.addManual(text: text)
                if let failure = outcome.failure {
                    env.feedback.show("添加失败：\(failure)")
                } else if outcome.added == 0 {
                    env.feedback.show("识别到 \(outcome.parsed) 条链接，都已经在队列或历史里了")
                } else {
                    let extra = outcome.duplicates > 0 ? "，跳过 \(outcome.duplicates) 条重复" : ""
                    env.feedback.show(
                        "已加入 \(outcome.added) 条下载\(extra)",
                        undoIDs: outcome.addedIDs
                    )
                }
            }
            // 消费事件：此时第一响应者不是可编辑文本，不存在需要粘贴的目标。
            return true
        }
    }

    /// 主窗口里挂了 MainWindowTagView，优先查视图树；再用 navigationTitle 兜底，
    /// 防止 SwiftUI 把背景里的 representable 从视图树里挪走导致判定失效。
    /// 设置窗口的标题是「通用 / liuying-engine / Downie / 高级」，不会撞上这三个主窗口标题。
    private static let mainWindowTitles: Set<String> = ["视频库", "队列", "订阅"]

    private static func isMainWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if let root = window.contentView, containsTagView(root) { return true }
        return mainWindowTitles.contains(window.title)
    }

    private static func containsTagView(_ view: NSView) -> Bool {
        if view is MainWindowTagView { return true }
        return view.subviews.contains { containsTagView($0) }
    }

    /// TextField / TextEditor / SecureField 聚焦时，firstResponder 是 field editor（NSTextView）。
    /// 沿响应链兜底几层，避免 SwiftUI 把第一响应者设在宿主 view 上时漏判。
    private static func isEditableResponder(_ responder: NSResponder?) -> Bool {
        var current = responder
        var depth = 0
        while let node = current, depth < 6 {
            depth += 1
            if let textView = node as? NSTextView, textView.isEditable { return true }
            if let field = node as? NSTextField, field.isEditable { return true }
            current = node.nextResponder
        }
        return false
    }
}

private enum PasteboardText {
    /// 普通文本优先；有些浏览器只放 URL flavor 不放字符串，补读一次。
    static func read() -> String {
        let board = NSPasteboard.general
        if let value = board.string(forType: .string), !value.isEmpty { return value }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] {
            let joined = urls.compactMap(\.absoluteString).joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }
        return ""
    }
}
