import Foundation

/// 应用身份与标准目录。改名只需动这里和 Resources/Info.plist。
public enum AppIdentity {
    public static let displayName = "流影"
    public static let executableName = "liuying"
    public static let bundleIdentifier = "im.yufei.liuying"

    /// 裸二进制（swift run / liuyingctl）没有 bundle id，回退到常量，
    /// 这样 OSLog subsystem 与 UserDefaults suite 在两种运行方式下保持一致。
    public static var effectiveBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? bundleIdentifier
    }

    /// 是否跑在真正的 .app bundle 里。UserNotifications 与 SMAppService 都要求这一点。
    public static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static let supportDirectory: String = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiuYing", isDirectory: true).path
    }()

    public static let logDirectory: String = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LiuYing", isDirectory: true).path
    }()

    public static var databasePath: String { (supportDirectory as NSString).appendingPathComponent("state.db") }
    public static var workDirectory: String { (supportDirectory as NSString).appendingPathComponent("work") }
    public static var backupsDirectory: String { (supportDirectory as NSString).appendingPathComponent("backups") }
    public static var thumbnailsDirectory: String { (supportDirectory as NSString).appendingPathComponent("thumbs") }

    /// 旧 Python 版的数据目录，只读用于首次清理 links.txt。
    public static let legacySupportDirectory: String = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bili-watcher", isDirectory: true).path
    }()

    public static var legacyDatabasePath: String {
        (legacySupportDirectory as NSString).appendingPathComponent("state.db")
    }

    /// `~` 展开 + 标准化。配置里的路径一律经此处理。
    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static func ensureDirectories() throws {
        for dir in [supportDirectory, logDirectory, workDirectory, backupsDirectory, thumbnailsDirectory] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}