import Foundation

/// 内嵌工具的定位：.app 里优先用 bundle 自带的二进制，裸二进制回退到 PATH。
///
/// `build-app.sh` 会把 Go 编译的 bili-dl 放进 `Contents/MacOS/`。从 .app 启动时
/// Bundle.main.executableURL 就是那个可执行文件，取同目录即得内嵌路径；从
/// `swift run` / `.build/release/liuyingctl` 启动时 bundleURL 不是 .app，回退查找 PATH。
public enum BundledTool {
    /// 内嵌 bili-dl 的绝对路径；没跑在 .app 里或文件不可执行时返回 nil。
    public static func bundledBiliDl() -> String? {
        guard AppIdentity.isBundledApp,
              let executable = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }
        let candidate = executable.appendingPathComponent("bili-dl").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// 解析配置里的工具路径：显式绝对路径 > 内嵌 > PATH。
    /// 配置填相对名（默认 "bili-dl"）时走内嵌优先，填绝对路径时尊重用户覆盖。
    public static func resolveBiliDl(configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("/") {
            let expanded = AppIdentity.expand(trimmed)
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        if let bundled = bundledBiliDl() { return bundled }
        return Subprocess.lookupOnPATH(trimmed)
    }
}
