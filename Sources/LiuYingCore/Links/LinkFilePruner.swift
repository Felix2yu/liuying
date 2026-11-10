import Foundation

/// 把已消费的链接从 links.txt 里删掉的 IO 层（纯逻辑在 `LinkPruner`）。
///
/// 定位：**卫生行为，不是正确性关键路径**。删不掉也不影响去重（URL 在任务表里已有 UNIQUE 键），
/// 所以这里宁可放弃一轮，也绝不冒覆盖 iPhone 并发追加的风险。
public enum LinkFilePruner {
    public struct Preview: Sendable, Equatable {
        public var path: String
        public var totalLines: Int
        public var removedLines: Int
        public var modifiedLines: Int
        public var removedURLs: Int
        public var previews: [String]

        public var changed: Bool { removedURLs > 0 }
    }

    public struct ApplyResult: Sendable {
        public var applied: Bool
        public var preview: Preview?
        public var backupPath: String?
        /// 未执行时的原因（给 UI / 日志看）。
        public var reason: String?
        /// 文件里本来就没有这些链接：不是失败，调用方应清掉待清理键而不是累加失败次数。
        public var nothingMatched: Bool = false
    }

    private struct Signature: Equatable {
        var mtime: Int64
        var size: Int64
    }

    private static func signature(_ path: String) -> Signature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Signature(
            mtime: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size)
        )
    }

    /// 只读预演，用于首次清理的确认 sheet。
    public static func preview(path: String, consumed: Set<String>) async -> Preview? {
        guard let text = await readText(path) else { return nil }
        let outcome = LinkPruner.prune(text: text, consumed: consumed)
        return Preview(
            path: path,
            totalLines: LinkPruner.splitLines(text).count,
            removedLines: outcome.removedLines,
            modifiedLines: outcome.modifiedLines,
            removedURLs: outcome.removedURLs,
            previews: outcome.previews
        )
    }

    /// 读 → 算 → 双 stat 防并发 → 备份 → 同目录临时文件 + replaceItemAt。
    public static func apply(
        path: String,
        consumed: Set<String>,
        backupDirectory: String?,
        readTimeout: TimeInterval = 120
    ) async -> ApplyResult {
        guard !consumed.isEmpty else {
            return ApplyResult(applied: false, preview: nil, backupPath: nil, reason: "没有待清理的链接")
        }
        guard let before = signature(path) else {
            return ApplyResult(applied: false, preview: nil, backupPath: nil, reason: "链接文件不存在或不可读")
        }
        guard let text = await readText(path, timeout: readTimeout) else {
            return ApplyResult(applied: false, preview: nil, backupPath: nil, reason: "读取链接文件失败")
        }

        let outcome = LinkPruner.prune(text: text, consumed: consumed)
        let preview = Preview(
            path: path,
            totalLines: LinkPruner.splitLines(text).count,
            removedLines: outcome.removedLines,
            modifiedLines: outcome.modifiedLines,
            removedURLs: outcome.removedURLs,
            previews: outcome.previews
        )
        guard outcome.changed else {
            return ApplyResult(
                applied: false, preview: preview, backupPath: nil,
                reason: "没有匹配到要删除的链接", nothingMatched: true
            )
        }

        // iPhone 可能在读取期间追加了一行；这时重写会把新内容吞掉，直接放弃本轮。
        guard signature(path) == before else {
            return ApplyResult(
                applied: false, preview: preview, backupPath: nil,
                reason: "文件在读取期间被修改（可能是手机刚写入），本轮放弃"
            )
        }

        var backupPath: String?
        if let backupDirectory {
            backupPath = writeBackup(text: text, sourcePath: path, directory: backupDirectory)
        }

        let directory = (path as NSString).deletingLastPathComponent
        // 临时名必须唯一：固定名会让两个清理动作（自动 + 手动）互相删掉对方的待替换文件。
        let temporary = (directory as NSString).appendingPathComponent(
            ".links.txt.liuying-\(UUID().uuidString).tmp"
        )
        let fm = FileManager.default
        do {
            try fm.removeItemIfExists(atPath: temporary)
            try Data(outcome.text.utf8).write(to: URL(fileURLWithPath: temporary))
            let original = URL(fileURLWithPath: path)
            let replacement = URL(fileURLWithPath: temporary)
            _ = try fm.replaceItemAt(original, withItemAt: replacement)
        } catch {
            try? fm.removeItemIfExists(atPath: temporary)
            return ApplyResult(
                applied: false, preview: preview, backupPath: backupPath,
                reason: "写入失败：\(error.localizedDescription)"
            )
        }

        Log.info(
            "链接文件已清理：删除 \(outcome.removedLines) 行、改写 \(outcome.modifiedLines) 行、"
            + "共 \(outcome.removedURLs) 个链接"
        )
        return ApplyResult(applied: true, preview: preview, backupPath: backupPath, reason: nil)
    }

    private static func readText(_ path: String, timeout: TimeInterval = 120) async -> String? {
        switch await DeadlinedRead.text(at: path, timeout: timeout) {
        case .success(let text): text
        default: nil
        }
    }

    private static func writeBackup(text: String, sourcePath: String, directory: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            // 同一秒里连做两次清理不能互相覆盖备份。
            let name = "links-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).txt"
            let target = (directory as NSString).appendingPathComponent(name)
            try Data(text.utf8).write(to: URL(fileURLWithPath: target))
            Log.info("已备份 \(sourcePath) → \(target)")
            return target
        } catch {
            Log.warning("备份链接文件失败：\(error.localizedDescription)")
            return nil
        }
    }
}

private extension FileManager {
    func removeItemIfExists(atPath path: String) throws {
        if fileExists(atPath: path) {
            try removeItem(atPath: path)
        }
    }
}