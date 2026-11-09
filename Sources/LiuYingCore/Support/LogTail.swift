import Foundation

/// 线程安全的日志尾部环形缓冲。
///
/// `Subprocess` 的行回调在后台私有队列上触发，引擎与 UI 又会同时读它，
/// 所以必须自己带锁（不能用 `@Observable` 的数组直接跨线程写）。
public final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public func append(_ line: String) {
        lock.lock()
        storage.append(line)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
        lock.unlock()
    }

    public var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public var text: String { snapshot.joined(separator: "\n") }

    public func clear() {
        lock.lock(); storage.removeAll(); lock.unlock()
    }
}