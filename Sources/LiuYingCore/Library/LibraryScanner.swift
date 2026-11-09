import CryptoKit
import Foundation

/// 扫描下载目录，构建视频库。
///
/// 完全以文件系统为真相：旧版状态库的 `out_path` 有空值、也有指向 /private/tmp 的陈旧测试路径，
/// 所以这里不读数据库。
public actor LibraryScanner {
    private var cache: [String: (stamp: Date, items: [LibraryVideo])] = [:]

    public init() {}

    /// 带死线的扫描。`~/Downloads` 在 TCC 待授权时枚举会无限阻塞，UI 不能干等。
    public func scan(root: String, timeout: TimeInterval = 20) async -> [LibraryVideo] {
        let standardizedRoot = (root as NSString).standardizingPath
        let stamp = directoryStamp(standardizedRoot)
        if let cached = cache[standardizedRoot], cached.stamp == stamp {
            return cached.items
        }

        let scanned = await GuardedFS.value(timeout: timeout) {
            Self.scanSync(root: standardizedRoot)
        } ?? nil
        guard let items = scanned else {
            Log.warning("扫描下载目录超时（可能缺少文件访问权限）：\(standardizedRoot)")
            return []
        }

        cache[standardizedRoot] = (stamp, items)
        return items
    }

    static func scanSync(root standardizedRoot: String) -> [LibraryVideo] {
        let url = URL(fileURLWithPath: standardizedRoot, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var items: [LibraryVideo] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else { continue }
            guard let item = LibraryPath.parse(
                path: fileURL.path,
                root: standardizedRoot,
                bytes: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast
            ) else { continue }
            items.append(item)
        }
        return items.sorted { $0.modified > $1.modified }
    }

    public func invalidate() {
        cache.removeAll()
    }

    /// 目录 mtime 作为廉价失效信号；下载完成后引擎会主动 invalidate 兜底。
    private func directoryStamp(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}

/// 缩略图：只在行展开时按需生成，缓存到 AppSupport/thumbs。
///
/// 不用 AVAssetImageGenerator —— AV1-in-mkv 它解不出来，ffmpeg 可以。
public actor Thumbnailer {
    private var inFlight: [String: Task<String?, Never>] = [:]

    public init() {}

    public func thumbnail(for path: String, maxWidth: Int = 560) async -> String? {
        let key = Self.cacheKey(path)
        let target = (AppIdentity.thumbnailsDirectory as NSString).appendingPathComponent("\(key).png")
        if FileManager.default.fileExists(atPath: target) { return target }
        if let existing = inFlight[path] { return await existing.value }

        let task = Task<String?, Never> { [target, path, maxWidth] in
            guard let ffmpeg = Subprocess.lookupOnPATH("ffmpeg") else { return nil }
            try? FileManager.default.createDirectory(
                atPath: AppIdentity.thumbnailsDirectory, withIntermediateDirectories: true
            )
            let result = await Subprocess.run(
                executable: ffmpeg,
                arguments: [
                    "-y", "-ss", "3", "-i", path,
                    "-frames:v", "1",
                    "-vf", "scale=\(maxWidth):-1",
                    "-f", "image2", target,
                ],
                environment: Subprocess.environment(),
                timeout: 20
            )
            guard result.exitCode == 0, FileManager.default.fileExists(atPath: target) else {
                Log.debug("缩略图生成失败：\(path) \(result.stderr.suffix(200))")
                return nil
            }
            return target
        }
        inFlight[path] = task
        let value = await task.value
        inFlight[path] = nil
        return value
    }

    static func cacheKey(_ path: String) -> String {
        // 路径 + 修改时间一起哈希：重下同一个文件（同名不同内容）也能刷出新缩略图。
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 }?.timeIntervalSince1970 ?? 0
        let digest = Insecure.MD5.hash(data: Data("\(path)|\(stamp)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}