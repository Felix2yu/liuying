import AppKit
import Foundation

/// iCloud 目录访问诊断。
///
/// 必须用 POSIX `opendir`/`errno`：`FileManager` 会把「权限拦截」和「不存在」都包装成
/// 同一个 NSError code，分不清是 TCC 挡了还是目录还没同步下来。
public enum PermissionProbe {
    public enum Status: Sendable, Equatable {
        case ok
        case permissionDenied(path: String)
        case permissionPending(path: String)
        case notCreated(path: String)
        case unreadable(path: String, message: String)

        public var isBlocking: Bool {
            switch self {
            case .ok, .notCreated: false
            case .permissionDenied, .permissionPending, .unreadable: true
            }
        }

        public var displayText: String {
            switch self {
            case .ok: "可访问"
            case .permissionDenied(let path): "权限被拦截：\(path)"
            case .permissionPending(let path): "访问被系统挂起（可能在等授权）：\(path)"
            case .notCreated(let path): "尚未创建：\(path)"
            case .unreadable(let path, let message): "无法读取 \(path)：\(message)"
            }
        }
    }

    /// 带死线的版本。**UI 必须用这个**：TCC 待授权时 `opendir` 会在 syscall 层无限阻塞，
    /// 直接在主线程调 `probe` 会让窗口卡死。
    public static func probeGuarded(path: String, timeout: TimeInterval = 3) async -> Status {
        if let status = await GuardedFS.value(timeout: timeout, { probe(path: path) }) {
            return status
        }
        return .permissionPending(path: path)
    }

    /// 逐级向上探测，返回最外层的阻塞原因；一路都能打开则返回 .ok / .notCreated。
    public static func probe(path: String) -> Status {
        var current = path
        var firstBlocking: Status?
        while true {
            errno = 0
            if let directory = opendir(current) {
                closedir(directory)
                if let blocking = firstBlocking { return blocking }
                // 最近的可打开目录若比目标浅，说明下面层级还没建。
                return current == path ? .ok : .notCreated(path: path)
            }
            switch errno {
            case EPERM, EACCES:
                firstBlocking = .permissionDenied(path: current)
            case ENOENT:
                break
            default:
                let message = String(cString: strerror(errno))
                firstBlocking = .unreadable(path: current, message: message)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return firstBlocking ?? .notCreated(path: path)
    }

    /// 系统设置 → 隐私与安全性 → 完全磁盘访问权限。
    public static let fullDiskAccessURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    public static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(fullDiskAccessURL)
    }
}
