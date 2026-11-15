import AppKit
import Foundation

/// ⌘V 的纯决策逻辑。
///
/// 只在这里决定「拦截并下载」还是「原样放行」，AppKit 层只负责采集现场状态。
/// 这样所有边界条件都能在没有窗口、没有剪贴板的单测里覆盖。
public enum PasteShortcut {
    public enum SkipReason: String, Sendable, Equatable {
        case disabled
        case inactive
        case notMainWindow
        case sheetPresent
        case textEditing
        case emptyClipboard
        case noLinks

        /// 只有「用户明显按了 ⌘V、但剪贴板里没有可下载内容」才给轻提示。
        /// 其余场景都是正常粘贴路径，绝不能弹东西打扰。
        public var notice: String? {
            switch self {
            case .emptyClipboard: "剪贴板是空的，没有触发下载"
            case .noLinks: "剪贴板里没有 http(s) 链接，未触发下载"
            case .disabled, .inactive, .notMainWindow, .sheetPresent, .textEditing: nil
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        /// 原样把事件交回系统（普通粘贴、非主窗口、输入框聚焦等）。
        case passthrough(SkipReason)
        /// 消费事件，把这些链接交给现有手动添加流程。
        case download([String])
    }

    /// 只认纯 ⌘V。⌘⇧V / ⌘⌥V / ⌃⌘V 等组合一律放行给系统，
    /// Caps Lock / 数字键盘 / Function 这些无关标志位不算额外修饰键。
    public static func isPlainCommandV(modifierFlags: UInt, characters: String) -> Bool {
        var flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
        flags.subtract([.capsLock, .numericPad, .function])
        guard flags == [.command] else { return false }
        return characters.lowercased() == "v"
    }

    /// - Parameters:
    ///   - isEnabled: 设置里的开关（默认开，用户可整体关掉）。
    ///   - isAppActive: `NSApp.isActive`。
    ///   - isMainWindowKey: 焦点窗口是打了标的主窗口，不是设置窗口／菜单栏面板。
    ///   - hasSheet: 主窗口上挂着 sheet，或有 modal window。
    ///   - isTextEditing: 第一响应者是可编辑文本控件（含 field editor）。
    ///   - clipboardText: 剪贴板文本；nil 等同于空。
    public static func evaluate(
        isEnabled: Bool,
        isAppActive: Bool,
        isMainWindowKey: Bool,
        hasSheet: Bool,
        isTextEditing: Bool,
        clipboardText: String?
    ) -> Decision {
        guard isEnabled else { return .passthrough(.disabled) }
        guard isAppActive else { return .passthrough(.inactive) }
        guard isMainWindowKey else { return .passthrough(.notMainWindow) }
        guard !hasSheet else { return .passthrough(.sheetPresent) }
        // 这一条是「避免影响普通粘贴场景」的核心：输入框里 ⌘V 永远是系统粘贴。
        guard !isTextEditing else { return .passthrough(.textEditing) }

        let text = clipboardText ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .passthrough(.emptyClipboard)
        }
        let urls = URLExtractor.extract(from: text)
        guard !urls.isEmpty else { return .passthrough(.noLinks) }
        return .download(urls)
    }
}
