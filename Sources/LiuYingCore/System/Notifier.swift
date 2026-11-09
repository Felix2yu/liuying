import Foundation
import UserNotifications

/// 桌面通知。用的是 UNUserNotificationCenter（不是旧版的 osascript）。
///
/// 关键守卫：`UNUserNotificationCenter.current()` 在**没有 app bundle** 时会直接让进程
/// 崩溃（`bundleProxyForCurrentProcess is nil`），所以裸二进制下所有调用都要短路。
@MainActor
public final class Notifier {
    public static let shared = Notifier()

    private var center: UNUserNotificationCenter? {
        guard Self.canManageBanners else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// 只有跑在 .app 里才有通知能力。
    public static var canManageBanners: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var authorized = false

    private init() {}

    /// 只在 `.notDetermined` 时弹授权框；已拒绝就安静跳过。
    public func requestAuthorizationIfNeeded() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound])
                Log.info("通知授权：\(authorized)")
            } catch {
                Log.warning("通知授权失败：\(error.localizedDescription)")
            }
        case .authorized, .provisional, .ephemeral:
            authorized = true
        default:
            authorized = false
        }
    }

    public func post(title: String, body: String, identifier: String = UUID().uuidString) {
        guard let center, authorized else {
            Log.info("[通知] \(title)：\(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        center.add(request) { error in
            if let error {
                Log.warning("通知投递失败：\(error.localizedDescription)")
            }
        }
    }
}

/// 把引擎的通知钩子接到 Notifier 上。
/// 用适配器而不是让 Notifier 直接实现协议，避免 @MainActor 与 nonisolated 的方法签名打架。
public struct NotificationBridge: EngineNotifying {
    public init() {}

    public func taskAdded(title: String, url: String) async {
        await MainActor.run {
            Notifier.shared.post(title: "发现新链接", body: "\(title)\n\(url)")
        }
    }

    public func taskFinished(title: String, outputPaths: [String]) async {
        let body = outputPaths.isEmpty
            ? "\(title)\n（文件已存在，跳过下载）"
            : "\(title)\n\(outputPaths.first ?? "")"
        await MainActor.run {
            Notifier.shared.post(title: "下载完成", body: body)
        }
    }

    public func taskFailed(title: String, error: String) async {
        await MainActor.run {
            Notifier.shared.post(title: "下载失败", body: "\(title)\n\(String(error.prefix(200)))")
        }
    }

    public func message(_ text: String) async {
        await MainActor.run {
            Notifier.shared.post(title: AppIdentity.displayName, body: text)
        }
    }
}