import Foundation

/// 读取 yutto 的登录态文件（默认 `~/.config/yutto/auth.toml`）。
///
/// 结构是 `[profiles.<name>]` 下的 `sessdata` / `bili_jct` / `updated_at`，
/// `sessdata` 也接受大写别名 `SESSDATA`。
/// 这里的值**绝不写日志**。
public enum AuthFile {
    public static func exists(path: String) -> Bool {
        FileManager.default.fileExists(atPath: AppIdentity.expand(path))
    }

    public static func sessdata(path: String, profile: String) -> String? {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let expanded = AppIdentity.expand(path)
        guard let data = FileManager.default.contents(atPath: expanded),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let tables = TOMLReader.parse(text)
        let tableName = "profiles.\(profile)"
        guard let table = tables[tableName] else { return nil }
        let value = table["sessdata"] ?? table["SESSDATA"]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// 设置里的手动覆盖优先，其次从 auth.toml 读。
    public static func resolveSessdata(override: String, path: String, profile: String) -> String? {
        let manual = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return sessdata(path: path, profile: profile)
    }
}