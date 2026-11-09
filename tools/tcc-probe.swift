// TCC 探针：验证一个 ad-hoc 签名的 .app 能否读写 iCloud Drive 里的快捷指令链接文件。
//
// 为什么需要它：本机 shell 访问 ~/Library/Mobile Documents 直接 EPERM，而旧版 Python 靠
// Homebrew 解释器能读通。新 .app 的 TCC 归属完全不同，必须先实测再决定架构分支。
// 用 POSIX opendir/open 而不是 FileManager，为的是拿到**真实 errno**（EPERM vs ENOENT），
// NSError 会把两者都包装成 257，分不清「被权限拦截」和「目录还没建」。
//
// 只读探测，绝不在 iCloud 目录里写任何东西。
//
// 实测教训（第一版踩到的）：结果必须**增量写盘**，且宽泛 glob `*/Documents/*/links.txt`
// 会遍历整棵 iCloud 树、卡在 lstat 上分钟级不返回。所以 glob 按序短路 + 每个都带死线。

import AppKit
import Darwin

let home = NSHomeDirectory()
let logDir = home + "/Library/Logs/LiuYing"
let resultPath = logDir + "/tcc-probe.txt"
let icloudRoot = home + "/Library/Mobile Documents"
let container = icloudRoot + "/iCloud~is~workflow~my~workflows"

let globPatterns = [
    icloudRoot + "/*/Documents/Bili/links.txt",
    icloudRoot + "/*/Shortcuts/Bili/links.txt",
    icloudRoot + "/com~apple~CloudDocs/Shortcuts/Bili/links.txt",
    icloudRoot + "/*/Documents/*/links.txt",
]

var lines: [String] = []

func emit(_ s: String) {
    lines.append(s)
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    try? (lines.joined(separator: "\n") + "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
}

func errText(_ e: Int32) -> String {
    "\(e) (\(String(cString: strerror(e))))"
}

func probeDir(_ path: String) -> String {
    errno = 0
    guard let dir = opendir(path) else { return "FAIL errno=\(errText(errno))" }
    var count = 0
    while readdir(dir) != nil { count += 1 }
    closedir(dir)
    errno = 0
    let writable = access(path, W_OK) == 0
    let writeErr = writable ? "" : " write-errno=\(errText(errno))"
    return "OK entries=\(max(0, count - 2)) writable=\(writable)\(writeErr)"
}

func probeFile(_ path: String) -> String {
    errno = 0
    let fd = open(path, O_RDONLY)
    if fd < 0 { return "FAIL errno=\(errText(errno))" }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    let n = read(fd, &buffer, buffer.count)
    let readErr = errno
    close(fd)
    if n < 0 { return "OPEN-OK READ-FAIL errno=\(errText(readErr))" }
    let lines = buffer.prefix(max(0, n)).split(separator: 0x0A, omittingEmptySubsequences: false).count
    return "OK bytes=\(n) lines=\(lines)"
}

func probeGlob(_ pattern: String) -> String {
    var g = glob_t()
    let rc = glob(pattern, GLOB_TILDE, nil, &g)
    defer { globfree(&g) }
    guard rc == 0, g.gl_matchc > 0 else {
        return "NO-MATCH rc=\(rc)（glob 分不清权限拦截与不存在，看上面的逐级探测）"
    }
    var hits: [String] = []
    for i in 0..<Int(g.gl_matchc) {
        if let c = g.gl_pathv[i] { hits.append(String(cString: c)) }
    }
    return hits.map { "\($0) → \(probeFile($0))" }.joined(separator: "\n      ")
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "(未完成)"
    func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

/// glob 可能分钟级不返回，放后台并设死线；超时的那次线程会泄漏，探针可接受。
func globWithDeadline(_ pattern: String, seconds: Double) -> String {
    let box = ResultBox()
    let sema = DispatchSemaphore(value: 0)
    let start = Date()
    DispatchQueue.global().async {
        box.set(probeGlob(pattern))
        sema.signal()
    }
    if sema.wait(timeout: .now() + seconds) == .timedOut {
        return "TIMEOUT >\(Int(seconds))s —— 遍历整棵 iCloud 树，不可用于每轮探测"
    }
    return String(format: "%.2fs %@", Date().timeIntervalSince(start), box.get())
}

func runProbe() {
    lines = []
    emit("=== LiuYing TCC 探针 \(ISO8601DateFormatter().string(from: Date())) ===")
    emit("bundle-id : \(Bundle.main.bundleIdentifier ?? "(none)")")
    emit("bundle    : \(Bundle.main.bundleURL.path)")
    emit("executable: \(Bundle.main.executableURL?.path ?? CommandLine.arguments[0])")
    emit("uid       : \(getuid())")
    emit("")

    emit("-- 对照组（应当 OK）--")
    emit("  ~/Downloads/Bilibili : \(probeDir(home + "/Downloads/Bilibili"))")
    emit("")

    emit("-- 逐级探测 iCloud（区分 EPERM 与 ENOENT）--")
    for (label, path) in [
        ("Mobile Documents", icloudRoot),
        ("快捷指令容器", container),
        ("容器/Documents", container + "/Documents"),
        ("容器/Documents/Bili", container + "/Documents/Bili"),
    ] {
        emit("  \(label) [\(path)]")
        emit("    \(probeDir(path))")
    }
    let linksFile = container + "/Documents/Bili/links.txt"
    emit("  links.txt [\(linksFile)]")
    emit("    \(probeFile(linksFile))")
    emit("")

    emit("-- 自动发现 glob（按序短路，命中即停；每个死线 8s）--")
    var found = false
    for pattern in globPatterns {
        emit("  \(pattern)")
        let result = globWithDeadline(pattern, seconds: 8)
        emit("    \(result)")
        if result.contains("→ OK") {
            found = true
            emit("    ↑ 命中，后续 glob 不再执行（与真实发现逻辑一致）")
            break
        }
    }
    emit("")
    emit(found ? "结论：自动发现可用。" : "结论：四个 glob 均未命中，看逐级探测判断是权限还是路径问题。")
}

// MARK: - 极简 UI：让探针留在前台，授权 FDA 后可以原地「重新检测」

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    let textView = NSTextView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "流影 · iCloud 权限探针"
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = textView
        content.addSubview(scroll)

        let reprobe = NSButton(title: "重新检测", target: self, action: #selector(reprobeTapped))
        let openFDA = NSButton(title: "打开完全磁盘访问权限…", target: self, action: #selector(openFDATapped))
        let quit = NSButton(title: "完成", target: self, action: #selector(quitTapped))
        let bar = NSStackView(views: [reprobe, openFDA, quit])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 探测放后台，避免卡住主线程导致窗口画不出来、结果也写不到盘。
        DispatchQueue.global().async { [self] in
            runProbe()
            DispatchQueue.main.async { [self] in textView.string = lines.joined(separator: "\n") }
        }
    }

    @objc func reprobeTapped() {
        textView.string = "探测中…"
        DispatchQueue.global().async { [self] in
            runProbe()
            DispatchQueue.main.async { [self] in textView.string = lines.joined(separator: "\n") }
        }
    }

    @objc func openFDATapped() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quitTapped() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()