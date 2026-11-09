import Foundation
import Observation

/// 配置的唯一权威存储。走**固定 suite** 的 UserDefaults，
/// 这样裸二进制（liuyingctl / swift run）与 .app 读到的是同一份配置。
@MainActor
@Observable
public final class ConfigStore {
    public nonisolated static let suiteName = "im.yufei.liuying"
    private static let storageKey = "app_config_v1"

    public private(set) var config: AppConfig
    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        let resolved = defaults ?? Self.effectiveDefaults
        self.defaults = resolved
        self.config = Self.load(from: resolved)
    }

    /// 固定 suite 的目的是让裸二进制（liuyingctl）与 .app 共用同一份偏好。
    /// 但 macOS 拒绝用 App 自己的 bundle id 当 suite 名（会退化成什么都不存），
    /// 所以 .app 走 .standard —— 它落到同一个 `im.yufei.liuying.plist`。
    public static var effectiveDefaults: UserDefaults {
        if AppIdentity.isBundledApp { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    private static func load(from defaults: UserDefaults) -> AppConfig {
        guard let data = defaults.data(forKey: storageKey) else {
            var fresh = AppConfig()
            fresh.normalize()
            return fresh
        }
        do {
            var config = try AppConfig.decode(fromJSON: data)
            config.normalize()
            return config
        } catch {
            Log.warning("配置解析失败，回退默认值：\(error)")
            return AppConfig()
        }
    }

    /// 改配置并立刻落盘。调用方负责之后再通知引擎刷新。
    public func update(_ mutate: (inout AppConfig) -> Void) {
        var next = config
        mutate(&next)
        next.normalize()
        guard next != config else { return }
        config = next
        save()
    }

    public func resetToDefaults() {
        var fresh = AppConfig()
        fresh.normalize()
        config = fresh
        save()
    }

    public func save() {
        do {
            defaults.set(try config.encodedJSON(), forKey: Self.storageKey)
        } catch {
            Log.error("配置保存失败：\(error)")
        }
    }

    /// 监听态文件的实际路径（空 = 自动发现由 ICloudLinkSource 负责）。
    public var resolvedWatchPath: String {
        config.watchFile.trimmingCharacters(in: .whitespaces).isEmpty
            ? "(自动发现)"
            : AppIdentity.expand(config.watchFile)
    }

    public var resolvedDownloadDir: String {
        AppIdentity.expand(config.downloadDir)
    }
}