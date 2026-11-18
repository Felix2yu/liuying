import Foundation

/// 跨设备去重键清单。
///
/// 解决的场景：新 Mac 装上端后 `state.db` 是空的，iCloud 里 links.txt 残留的行会被
/// 全量当成新链接下载。做法是让旧机把已入队过的去重键写进一份纯文本清单，放到 links.txt
/// 同目录随 iCloud 同步；新机启动、采集链接之前先把清单里的键导回本地库，之后的去重
/// 照常由 `knownKeys()` 完成。
///
/// 为什么不直接同步 `state.db`：SQLite 的 WAL/-shm 与 iCloud 的逐文件同步、冲突副本机制
/// 不兼容，多机同写极易损坏库。清单是**单向追加、可并集合并**的纯文本，天然抗冲突。
///
/// 所有 IO 都带死线：iCloud 占位符首次访问会触发云端下载，TCC 待授权时 `open` 会在
/// syscall 层阻塞，不能让引擎/界面一起卡住。
public enum KnownKeySync {
    /// 与 links.txt 同目录，随同一个 iCloud 容器同步。
    public static let fileName = "liuying-known-keys.txt"

    // MARK: - 纯逻辑（可单测）

    /// 解析清单文本：忽略空行、以 `#` 开头的注释与首尾空白。
    /// 键本身可能是 URL（含 `#` 片段），但只会以 http/BV/av 开头，不会被当成注释。
    public static func decode(_ text: String) -> Set<String> {
        var result: Set<String> = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            result.insert(String(line))
        }
        return result
    }

    /// 稳定排序输出，便于人肉核对与 diff。尾部换行保证下次追加不粘行。
    public static func encode(keys: Set<String>) -> String {
        var lines = ["# \(AppIdentity.displayName) 去重键清单 · 每行一个键 · 由程序自动维护"]
        lines.append(contentsOf: keys.sorted())
        return lines.joined(separator: "\n") + "\n"
    }

    /// 并集合并：只读本地新增，绝不删除文件里已有的键。
    /// 两台 Mac 同时写时，后写的一方会带上前一方的全部键，不会互相覆盖。
    public static func merge(existing: Set<String>, adding: Set<String>) -> Set<String> {
        existing.union(adding)
    }

    public static func manifestPath(forLinkFile linkPath: String) -> String {
        ((linkPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(fileName)
    }

    // MARK: - 结果类型

    public enum ReadResult: Sendable, Equatable {
        case keys(Set<String>)
        /// 清单尚未创建（新用户，或从没导出过）——正常情况，不是错误。
        case missing
        case failed(String)

        public var keysOrEmpty: Set<String> {
            if case .keys(let keys) = self { return keys }
            return []
        }
    }

    public enum WriteResult: Sendable, Equatable {
        case written(count: Int)
        case failed(String)
    }

    public struct ActionResult: Sendable, Equatable {
        public var ok: Bool
        public var count: Int
        public var message: String

        public init(ok: Bool, count: Int, message: String) {
            self.ok = ok
            self.count = count
            self.message = message
        }
    }

    // MARK: - IO

    /// 读清单。超时/读取失败都返回 failed，由调用方决定要不要提示用户。
    public static func read(path: String, timeout: TimeInterval = 30) async -> ReadResult {
        switch await DeadlinedRead.text(at: path, timeout: timeout) {
        case .success(let text):
            return .keys(decode(text))
        case .failure(let message):
            // 文件不存在是新用户常态，单独区分出来，避免首轮启动就报错。
            if isMissing(path) { return .missing }
            return .failed(message)
        case .timeout:
            return .failed("读取超时（可能在等 iCloud 下载或系统授权）")
        }
    }

    /// 把 `adding` 并入清单文件：读现有 → 并集 → 双 stat 防并发 → 同目录临时文件 + 原子替换。
    /// 清单是派生数据（可从任务库重建），故不做逐次备份——links.txt 才是不可再生的用户数据。
    public static func addKeys(
        _ adding: Set<String>,
        to path: String,
        timeout: TimeInterval = 30
    ) async -> WriteResult {
        guard !adding.isEmpty else { return .written(count: 0) }
        let outcome: WriteOutcome? = await GuardedFS.value(timeout: timeout) {
            writeSync(adding, to: path)
        }
        guard let outcome else {
            return .failed("写入超时（可能在等 iCloud 或系统授权）")
        }
        switch outcome {
        case .written(let count): return .written(count: count)
        case .failed(let message): return .failed(message)
        }
    }

    // MARK: - 同步实现（在 GuardedFS 的后台线程上跑，全程不碰 actor 状态）

    private enum WriteOutcome {
        case written(count: Int)
        case failed(String)
    }

    private struct Signature: Equatable {
        var mtime: Int64
        var size: Int64
    }

    private static func signature(_ path: String) -> Signature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Signature(
            mtime: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size)
        )
    }

    private static func isMissing(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) != 0 && errno == ENOENT
    }

    private static func writeSync(_ adding: Set<String>, to path: String) -> WriteOutcome {
        let before = signature(path)

        let existing: Set<String>
        switch readRaw(path) {
        case .missing:
            existing = []
        case .success(let text):
            existing = decode(text)
        case .failure(let message):
            return .failed("读取现有清单失败：\(message)")
        }

        let merged = merge(existing: existing, adding: adding)
        // 读的期间若文件被改（另一台 Mac 刚写入），放弃本轮，下一轮重读再并，绝不吞键。
        guard signature(path) == before else {
            return .failed("清单在读取期间被修改，本轮放弃")
        }

        let directory = (path as NSString).deletingLastPathComponent
        let temporary = (directory as NSString).appendingPathComponent(
            ".liuying-known-keys-\(UUID().uuidString).tmp"
        )
        let fm = FileManager.default
        do {
            try Data(encode(keys: merged).utf8).write(to: URL(fileURLWithPath: temporary))
            _ = try fm.replaceItemAt(
                URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary)
            )
        } catch {
            try? fm.removeItem(atPath: temporary)
            return .failed("写入清单失败：\(error.localizedDescription)")
        }
        return .written(count: merged.count)
    }

    private enum RawRead {
        case success(String)
        case missing
        case failure(String)
    }

    private static func readRaw(_ path: String) -> RawRead {
        errno = 0
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            if errno == ENOENT { return .missing }
            return .failure(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            errno = 0
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { return .failure(String(cString: strerror(errno))) }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return .success(String(decoding: data, as: UTF8.self))
    }
}
