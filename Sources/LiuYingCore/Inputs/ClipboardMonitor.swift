import AppKit
import Foundation

/// 剪贴板监听。挂在引擎同一个 tick 上，不另起定时器。
///
/// 默认关闭（配置里 `clipboard_monitor`）：剪贴板是环境输入，
/// 自动触发下载要用户主动开启。开启后抓取任意 http(s) 链接 —— B 站以外的
/// 会按当前路由交给 Downie，不是「只认 B 站链接」。
public final class ClipboardMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastChangeCount: Int

    public init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// 返回本次新复制内容里的 B 站链接；没有变化或没有链接时返回空数组。
    public func poll() -> [String] {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount

        lock.lock()
        let changed = changeCount != lastChangeCount
        if changed { lastChangeCount = changeCount }
        lock.unlock()

        guard changed, let text = pasteboard.string(forType: .string) else { return [] }
        return URLExtractor.extract(from: text)
    }
}