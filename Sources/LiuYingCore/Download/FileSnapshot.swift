import Foundation

/// 下载目录的文件集快照。用「前后差集」判断 yutto 产出了什么，
/// 因为 yutto 的文件名由 `subpath_template` 决定，脚本侧推不出来。
public struct FileSnapshot: Sendable, Equatable {
    public var files: Set<String>

    public static let empty = FileSnapshot(files: [])

    /// 带死线的快照。
    /// - Returns: nil 表示枚举超时或没有权限。调用方必须把它当成失败，
    ///   而不是「没有新文件」—— 否则会把一次没跑成的下载误判成「已存在」。
    public static func capture(root: String, timeout: TimeInterval = 20) async -> FileSnapshot? {
        await GuardedFS.value(timeout: timeout) { captureSync(root: root) } ?? nil
    }

    /// 递归收集**媒体文件**。封面/字幕/弹幕这类附属产物不进快照，
    /// 否则会污染「新文件」列表（旧版还会被 `.DS_Store` 干扰）。
    static func captureSync(root: String) -> FileSnapshot {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }
        var files = Set<String>()
        for case let url as URL in enumerator {
            guard LibraryPath.mediaExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.insert(url.path)
        }
        return FileSnapshot(files: files)
    }

    /// 新增文件，按路径排序保证顺序稳定（多 P 就是 01、02……）。
    public func newFiles(comparedTo before: FileSnapshot) -> [String] {
        files.subtracting(before.files).sorted()
    }
}