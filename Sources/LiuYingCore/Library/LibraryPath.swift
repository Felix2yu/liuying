import Foundation

/// 视频库里的一个媒体文件。
///
/// 库完全以**文件系统为真相**：旧版状态库的 `out_path` 有空值、也有指向 /private/tmp 的
/// 陈旧测试路径，不能拿来展示。UP 主与标题从路径分段解析。
public struct LibraryVideo: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    /// `<root>/<UP主>/<标题>.ext` 的第一段；直接放在根目录时为 nil。
    public var owner: String?
    public var title: String
    /// 多 P 的页码标签，例如 `01` 或 `03 · 分P名`。
    public var pageLabel: String?
    public var container: String
    public var bytes: Int64
    public var modified: Date

    public init(
        path: String, owner: String?, title: String,
        pageLabel: String? = nil, container: String, bytes: Int64, modified: Date
    ) {
        self.path = path
        self.owner = owner
        self.title = title
        self.pageLabel = pageLabel
        self.container = container
        self.bytes = bytes
        self.modified = modified
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    /// 用于分组的展示标题：多 P 时带上页码。
    public var displayTitle: String {
        guard let pageLabel else { return title }
        return "\(title) · P\(pageLabel)"
    }
}

public enum LibraryPath {
    public static let mediaExtensions: Set<String> = ["mkv", "mp4", "mov", "flv", "webm", "m4a", "mp3"]

    /// - Returns: nil 表示不是媒体文件（`.DS_Store`、字幕、封面等）。
    public static func parse(path: String, root: String, bytes: Int64, modified: Date) -> LibraryVideo? {
        let standardizedPath = (path as NSString).standardizingPath
        let standardizedRoot = (root as NSString).standardizingPath

        var relative = standardizedPath
        let rootPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        if relative != standardizedRoot, relative.hasPrefix(rootPrefix) {
            relative = String(relative.dropFirst(rootPrefix.count))
        }
        relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let components = relative
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let last = components.last else { return nil }

        let ext = (last as NSString).pathExtension.lowercased()
        guard mediaExtensions.contains(ext) else { return nil }

        // 至少 root 下直接放文件；有子目录时第一段视为 UP 主。
        let owner = components.count >= 2 ? components[0] : nil
        let baseName = (last as NSString).deletingPathExtension
        let (title, pageLabel) = splitPageLabel(baseName)

        return LibraryVideo(
            path: standardizedPath,
            owner: owner,
            title: title,
            pageLabel: pageLabel,
            container: ext,
            bytes: bytes,
            modified: modified
        )
    }

    /// yutto 的分 P 命名在不同版本/参数下有两种形态，两种都认：
    /// `标题(1)` / `标题（1）` 与 `标题 - 01 - 分P名`。
    /// 实际命名以 Milestone 5 的真实多 P 下载为准，届时按观测结果收紧。
    static func splitPageLabel(_ baseName: String) -> (title: String, page: String?) {
        if let match = trailingParenPage.firstMatch(
            in: baseName, range: NSRange(location: 0, length: (baseName as NSString).length)
        ) {
            let ns = baseName as NSString
            let base = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let page = ns.substring(with: match.range(at: 2))
            if !base.isEmpty { return (base, page) }
        }
        if let match = dashPage.firstMatch(
            in: baseName, range: NSRange(location: 0, length: (baseName as NSString).length)
        ) {
            let ns = baseName as NSString
            let base = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let page = ns.substring(with: match.range(at: 2))
            let part = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
            if !base.isEmpty { return (base, "\(page) · \(part)") }
        }
        return (baseName, nil)
    }

    static let trailingParenPage = try! NSRegularExpression(
        pattern: #"^(.*?)\s*[（(](\d{1,3})[）)]$"#
    )
    static let dashPage = try! NSRegularExpression(
        pattern: #"^(.*?)\s+-\s+(\d{1,3})\s+-\s+(.+)$"#
    )
}