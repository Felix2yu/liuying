import Foundation

/// iCloud Drive 自动发现。
///
/// 两条硬约束（都是实测踩出来的）：
///  1. **必须命中即短路**。旧版第 4 条宽泛模式 `*/Documents/*/links.txt` 会遍历整棵 iCloud 树，
///     卡在 `lstat` 上分钟级不返回，而自动发现每轮都可能重跑。
///  2. **全部调用必须带死线**。TCC 待授权时 `opendir` 会在 syscall 层无限阻塞。
public enum ICloudDiscovery {
    public static let root = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Mobile Documents")

    /// iOS 快捷指令写的是它自己的 app 容器，不是常规的 com~apple~CloudDocs。
    public static let shortcutsContainer = "iCloud~is~workflow~my~workflows"

    public static var placeholderPath: String {
        (root as NSString).appendingPathComponent("\(shortcutsContainer)/Documents/Bili/links.txt")
    }

    /// 窄模式：一次目录列举 + 定点存在性检查，成本可控。
    /// - Returns: nil 表示没找到，或探测超时。
    public static func discoverNarrow(timeout: TimeInterval = 5) async -> String? {
        let result = await GuardedFS.value(timeout: timeout) { narrowSync() }
        return result ?? nil
    }

    /// 宽泛回退：`*/Documents/*/links.txt`。只在窄模式落空时偶尔跑，且限条目数。
    public static func discoverBroad(
        containerLimit: Int = 40,
        timeout: TimeInterval = 8
    ) async -> String? {
        let result = await GuardedFS.value(timeout: timeout) {
            broadSync(containerLimit: containerLimit)
        }
        return result ?? nil
    }

    static func narrowSync() -> String? {
        let fm = FileManager.default
        let candidates = ["Documents/Bili/links.txt", "Shortcuts/Bili/links.txt"]

        // 快捷指令容器优先（iOS 端的实际落点）。
        for relative in candidates {
            let path = (root as NSString).appendingPathComponent("\(shortcutsContainer)/\(relative)")
            if fm.fileExists(atPath: path) { return path }
        }
        let cloudDocs = (root as NSString).appendingPathComponent("com~apple~CloudDocs/Shortcuts/Bili/links.txt")
        if fm.fileExists(atPath: cloudDocs) { return cloudDocs }

        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for entry in entries.sorted() where entry != shortcutsContainer && entry != "com~apple~CloudDocs" {
            for relative in candidates {
                let path = (root as NSString)
                    .appendingPathComponent(entry)
                    .appending("/\(relative)")
                if fm.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    static func broadSync(containerLimit: Int) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for entry in entries.sorted().prefix(containerLimit) {
            let documents = (root as NSString).appendingPathComponent("\(entry)/Documents")
            guard let subdirs = try? fm.contentsOfDirectory(atPath: documents) else { continue }
            for subdir in subdirs.sorted() {
                let path = (documents as NSString).appendingPathComponent("\(subdir)/links.txt")
                if fm.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }
}