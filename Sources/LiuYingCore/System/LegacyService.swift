import Foundation

/// 旧版 Python 服务的退役/恢复。
///
/// 用户明确要求「终止运行并且不再开机自启」。这里做成**可逆**的：
/// 先 bootout，确认进程真的没了，再把 plist 移走（绝不删），恢复时移回并 bootstrap。
public enum LegacyService {
    public static let label = "com.felix2yu.bili-watcher"
    static let launchAgentsDirectory = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/LaunchAgents")
    public static var plistPath: String {
        (launchAgentsDirectory as NSString).appendingPathComponent("\(label).plist")
    }
    static var disabledDirectory: String {
        (AppIdentity.backupsDirectory as NSString).appendingPathComponent("launchagents")
    }

    public struct Status: Sendable, Equatable {
        public var loaded: Bool
        public var pid: Int32?
        public var plistInstalled: Bool

        public var displayText: String {
            if let pid, loaded { return "运行中（PID \(pid)）" }
            if loaded { return "已加载但未运行" }
            if plistInstalled { return "未加载（plist 仍在）" }
            return "未安装"
        }

        public var needsRetire: Bool { loaded || plistInstalled }
    }

    public static func status() async -> Status {
        let result = await Subprocess.run(
            executable: "/bin/launchctl",
            arguments: ["list", label],
            environment: Subprocess.environment(),
            timeout: 10
        )
        var pid: Int32?
        var loaded = false
        if result.exitCode == 0 {
            loaded = true
            // 输出形如 "2584\t0\tcom.felix2yu.bili-watcher"
            let firstLine = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
            let firstField = firstLine.split(separator: "\t").first.map(String.init) ?? ""
            if let parsed = Int32(firstField) { pid = parsed }
        }
        let plistInstalled = FileManager.default.fileExists(atPath: plistPath)

        // launchctl 说在跑不代表进程真的活着，用 kill(pid, 0) 复核。
        if let pid, loaded, kill(pid, 0) != 0 {
            return Status(loaded: true, pid: nil, plistInstalled: plistInstalled)
        }
        return Status(loaded: loaded, pid: pid, plistInstalled: plistInstalled)
    }

    public struct RetireResult: Sendable {
        public var ok: Bool
        public var message: String
        public var movedPlistTo: String?
    }

    /// bootout → 确认 PID 消失 → 移走 plist → disable。
    public static func retire() async -> RetireResult {
        let before = await status()
        var notes: [String] = []

        if before.loaded {
            let bootout = await Subprocess.run(
                executable: "/bin/launchctl",
                arguments: ["bootout", "gui/\(getuid())/\(label)"],
                environment: Subprocess.environment(),
                timeout: 15
            )
            if bootout.exitCode != 0 {
                notes.append("bootout 返回 \(bootout.exitCode)：\(bootout.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        // 给 launchd 一点时间收尾，然后独立复核一次。
        try? await Task.sleep(nanoseconds: 800_000_000)
        let after = await status()
        if after.loaded {
            if let pid = after.pid, kill(pid, 0) == 0 {
                return RetireResult(ok: false, message: "旧服务仍在运行（PID \(pid)），停用失败", movedPlistTo: nil)
            }
            return RetireResult(ok: false, message: "旧服务仍被 launchd 加载，停用失败", movedPlistTo: nil)
        }

        var movedTo: String?
        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath) {
            do {
                try fm.createDirectory(atPath: disabledDirectory, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let target = (disabledDirectory as NSString)
                    .appendingPathComponent("\(label).plist.disabled-\(formatter.string(from: Date()))")
                try fm.moveItem(atPath: plistPath, toPath: target)
                movedTo = target
                notes.append("plist 已移到 \(target)")
            } catch {
                return RetireResult(
                    ok: false,
                    message: "服务已停止，但移走 plist 失败：\(error.localizedDescription)",
                    movedPlistTo: nil
                )
            }
        }

        // 写进 launchd 的 disabled 数据库，防止别处再 bootstrap。
        _ = await Subprocess.run(
            executable: "/bin/launchctl",
            arguments: ["disable", "gui/\(getuid())/\(label)"],
            environment: Subprocess.environment(),
            timeout: 10
        )

        Log.info("旧版 Python 服务已停用。\(notes.joined(separator: "；"))")
        return RetireResult(
            ok: true,
            message: notes.isEmpty ? "旧服务已停用" : notes.joined(separator: "；"),
            movedPlistTo: movedTo
        )
    }

    /// 恢复：enable → 把 plist 移回 → bootstrap。
    public static func restore() async -> RetireResult {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: plistPath) else {
            return RetireResult(ok: false, message: "plist 已经在了，无需恢复", movedPlistTo: nil)
        }
        guard let candidate = try? fm.contentsOfDirectory(atPath: disabledDirectory)
            .filter({ $0.hasPrefix(label) })
            .sorted()
            .last else {
            return RetireResult(ok: false, message: "找不到被移走的 plist", movedPlistTo: nil)
        }
        do {
            try fm.moveItem(
                atPath: (disabledDirectory as NSString).appendingPathComponent(candidate),
                toPath: plistPath
            )
        } catch {
            return RetireResult(ok: false, message: "移回 plist 失败：\(error.localizedDescription)", movedPlistTo: nil)
        }
        _ = await Subprocess.run(
            executable: "/bin/launchctl",
            arguments: ["enable", "gui/\(getuid())/\(label)"],
            environment: Subprocess.environment(),
            timeout: 10
        )
        let bootstrap = await Subprocess.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", plistPath],
            environment: Subprocess.environment(),
            timeout: 15
        )
        guard bootstrap.exitCode == 0 else {
            return RetireResult(
                ok: false,
                message: "bootstrap 失败：\(bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                movedPlistTo: nil
            )
        }
        let status = await self.status()
        return RetireResult(
            ok: status.loaded,
            message: status.loaded ? "旧服务已恢复" : "bootstrap 执行了但服务未加载",
            movedPlistTo: nil
        )
    }
}