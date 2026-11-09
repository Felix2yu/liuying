import Foundation

/// 只允许第一个调用者恢复 continuation 的小开关。
/// 用于「后台工作」与「超时」二选一的竞速，避免重复 resume 导致崩溃。
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 给可能永久阻塞的调用套上死线，**且不阻塞任何线程**。
///
/// 为什么必须这样：对 `~/Library/Mobile Documents` 的访问在 TCC 待授权时会在 syscall 层
/// 直接阻塞（实测 `opendir` / `open` 挂住不返回，也不报 EPERM）。
/// 如果用一个 `DispatchSemaphore.wait` 做超时，等待方自己也会占住一个协作线程 ——
/// 在 actor 或主线程上就是卡死界面。这里改成「后台跑工作 + 定时器抢答」。
public enum GuardedFS {
    /// - Returns: nil 表示超时。
    public static func value<T: Sendable>(
        timeout: TimeInterval,
        _ work: @escaping @Sendable () -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            DispatchQueue.global(qos: .utility).async {
                let result = work()
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}