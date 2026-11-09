import Foundation
import ServiceManagement

/// 登录时自启。只对真正的 .app 有效：`swift run` 出来的裸二进制会抛 LaunchServices 错误，
/// 这里把它变成用户可见的提示而不是崩溃。
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已启用"
        case .notRegistered: "未启用"
        case .requiresApproval: "需在系统设置中批准"
        case .notFound: "未找到（需从 .app 运行）"
        @unknown default: "未知"
        }
    }

    /// - Returns: nil 表示成功，否则是给用户看的错误文案。
    public static func setEnabled(_ enabled: Bool) -> String? {
        guard AppIdentity.isBundledApp else {
            return "只在 .app 里运行时才能设置开机启动（当前是裸二进制）"
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "设置开机启动失败：\(error.localizedDescription)"
        }
    }
}