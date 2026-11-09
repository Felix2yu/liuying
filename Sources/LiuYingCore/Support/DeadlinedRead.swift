import Foundation

/// 带死线的文件读取。
///
/// iCloud 占位符首次读取会触发云端下载，且 TCC 待授权时 `open` 会在 syscall 层阻塞；
/// 调用方不能无限等，也不能用信号量把自己卡住（那会在 actor / 主线程上冻住界面）。
/// 所以：后台线程读，定时器抢答，先到者恢复 continuation。
public enum DeadlinedRead {
    public enum Outcome: Sendable, Equatable {
        case success(String)
        case timeout
        case failure(String)
    }

    public static func text(at path: String, timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            DispatchQueue.global(qos: .utility).async {
                let outcome = readFile(path)
                if once.claim() { continuation.resume(returning: outcome) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: .timeout) }
            }
        }
    }

    /// POSIX 读，刻意不用 `Data(contentsOf:)`：
    /// 后者会走 Foundation 的文件协调（NSFileCoordinator），在 iCloud 占位符上会长时间挂住；
    /// POSIX `open`/`read` 与 TCC 探针用的是同一条路径，实测瞬间返回。
    static func readFile(_ path: String) -> Outcome {
        errno = 0
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            return .failure("打开失败：\(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            errno = 0
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                return .failure("读取失败：\(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        // 非法字节按替换字符处理，与旧版 Python 的 errors="replace" 一致；
        // 同时保留 BOM（String(decoding:) 不会吞掉它）。
        return .success(String(decoding: data, as: UTF8.self))
    }
}