// liuyingctl —— 无界面验证入口。
//
// 注意：直接跑二进制时 TCC 归属算到终端头上，iCloud 目录会 EPERM（Milestone 0 实测）。
// 所以这里只做下载/状态/环境类验证，iCloud 读写必须经 .app 走 LaunchServices。

import Foundation
import LiuYingCore

func doctor() {
    print("=== \(AppIdentity.displayName) 环境自检 ===")
    print("bundle id  : \(AppIdentity.effectiveBundleIdentifier)")
    print("跑在 .app 里: \(AppIdentity.isBundledApp)")
    print("数据目录   : \(AppIdentity.supportDirectory)")
    print("日志文件   : \(Log.logFilePath)")
    print("状态库     : \(AppIdentity.databasePath)")
    print("")

    print("-- 子进程 PATH --")
    print(Subprocess.enhancedPATH)
    print("")

    print("-- 外部依赖解析 --")
    for tool in ["yutto", "ffmpeg", "ffprobe"] {
        let resolved = Subprocess.lookupOnPATH(tool) ?? "(未找到)"
        print("  \(tool.padding(toLength: 8, withPad: " ", startingAt: 0)) \(resolved)")
    }
    print("")

    do {
        try AppIdentity.ensureDirectories()
        print("目录创建   : OK")
    } catch {
        print("目录创建   : 失败 \(error.localizedDescription)")
    }

    do {
        let db = try SQLiteDatabase(path: ":memory:")
        let version = try db.queryOne("SELECT sqlite_version() AS v;")?.text("v") ?? "?"
        print("SQLite     : \(version)")
    } catch {
        print("SQLite     : 失败 \(error)")
    }

    if let yutto = Subprocess.lookupOnPATH("yutto") {
        print("")
        print("-- yutto --version --")
        let result = Subprocess.runBlocking(
            executable: yutto, arguments: ["--version"],
            environment: Subprocess.environment(), timeout: 30
        )
        print("exit=\(result.exitCode) launched=\(result.launched)")
        print((result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

func biliRaw(_ mid: Int64) async {
    let config = AppConfig()
    let sessdata = AuthFile.resolveSessdata(
        override: config.sessdataOverride,
        path: config.yutto.authFile,
        profile: config.yutto.authProfile
    )
    let client = BiliClient(sessdata: sessdata)
    do {
        print(try await client.rawArcSearch(mid: mid))
    } catch {
        print("失败：\(error.localizedDescription)")
        exit(1)
    }
}

func biliSign(_ mid: Int64) async {
    let config = AppConfig()
    let sessdata = AuthFile.resolveSessdata(
        override: config.sessdataOverride,
        path: config.yutto.authFile,
        profile: config.yutto.authProfile
    )
    let client = BiliClient(sessdata: sessdata)
    do {
        let debug = try await client.signatureDebug(mid: mid)
        print("img_key   \(debug.imgKey)")
        print("sub_key   \(debug.subKey)")
        print("mixin_key \(debug.mixinKey)")
        print("wts       \(debug.timestamp)")
        print("query     \(debug.query)")
    } catch {
        print("失败：\(error.localizedDescription)")
        exit(1)
    }
}

func biliSmoke(_ bvid: String) async {
    print("=== B 站接口 smoke ===")
    let config = AppConfig()
    let sessdata = AuthFile.resolveSessdata(
        override: config.sessdataOverride,
        path: config.yutto.authFile,
        profile: config.yutto.authProfile
    )
    if let sessdata {
        print("SESSDATA : 已加载（\(sessdata.count) 字符，不打印值）")
    } else {
        print("SESSDATA : 未找到，走匿名（大概率被风控 -352）")
        print("           路径 \(AppIdentity.expand(config.yutto.authFile)) profile=\(config.yutto.authProfile)")
    }

    let client = BiliClient(sessdata: sessdata)
    do {
        let keys = try await client.navKeys()
        print("WBI keys : img=\(keys.img.count)字符  sub=\(keys.sub.count)字符")
        let mixin = WBISigner.mixinKey(imgKey: keys.img, subKey: keys.sub)
        print("mixin    : \(mixin.count)字符")

        let detail = try await client.view(bvid: bvid)
        print("")
        print("view     : \(detail.title)")
        print("  owner  : \(detail.ownerName ?? "?")  mid=\(detail.ownerMid.map(String.init) ?? "?")")
        print("  pubdate: \(detail.pubdate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil")")
        print("  duration: \(detail.duration.map(String.init) ?? "nil") 秒   pages=\(detail.pages.count)")
        for page in detail.pages.prefix(3) {
            print("    P\(page.page) cid=\(page.cid.map(String.init) ?? "nil") \(page.part)")
        }

        if let mid = detail.ownerMid {
            let result = try await client.arcSearch(mid: mid, page: 1)
            print("")
            print("arc/search mid=\(mid): total=\(result.totalCount)  本页=\(result.videos.count)")
            for video in result.videos.prefix(5) {
                let created = video.created.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
                print("  \(video.bvid)  created=\(created)")
                print("    \(video.title)")
            }
        }
        print("")
        print("结论：真实接口可用。")
    } catch {
        print("")
        print("失败：\(error.localizedDescription)")
        exit(1)
    }
}

func legacyStatus() {
    print("=== 旧版 Python bili-watcher ===")
    print("数据目录: \(AppIdentity.legacySupportDirectory)")
    print("状态库  : \(AppIdentity.legacyDatabasePath)")
    let exists = FileManager.default.fileExists(atPath: AppIdentity.legacyDatabasePath)
    print("库存在  : \(exists)")
    guard exists else { return }

    let tasks = LegacyReader.completedTasks()
    print("已完成  : \(tasks.count) 条")
    for task in tasks {
        print("  \(task.taskKey)\t\(task.rawURL)")
    }
    let keys = LegacyReader.completedKeys()
    print("去重键  : \(keys.count) 个（task_key ∪ raw_url）")
}

func biliFindMultiPage(mid: Int64, maxScan: Int) async {
    let config = AppConfig()
    let sessdata = AuthFile.resolveSessdata(
        override: config.sessdataOverride,
        path: config.yutto.authFile,
        profile: config.yutto.authProfile
    )
    let client = BiliClient(sessdata: sessdata)
    do {
        let list = try await client.latestUploads(mid: mid, pageSize: 49)
        print("mid=\(mid) 最近 \(list.count) 条投稿，最多扫 \(maxScan) 条")
        for (index, video) in list.prefix(maxScan).enumerated() {
            let detail = try await client.view(bvid: video.bvid)
            if detail.pages.count > 1 {
                print("")
                print("找到多 P：\(video.bvid)  pages=\(detail.pages.count)")
                print("  \(detail.title)")
                for page in detail.pages.prefix(6) {
                    print("  P\(page.page) \(page.part)")
                }
                return
            }
            if index % 10 == 0 { print("  已扫 \(index + 1)…") }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        print("这 \(min(maxScan, list.count)) 条里没有多 P")
    } catch {
        print("失败：\(error.localizedDescription)")
        exit(1)
    }
}

/// 只打印路由决策与将要执行的命令，**不下载**。用来确认「B 站 → yutto，其它 → Downie」。
func routeReport(_ urls: [String]) async {
    let config = await MainActor.run { ConfigStore().config }
    let downloadDir = AppIdentity.expand(config.downloadDir)
    print("下载目录: \(downloadDir)")
    print("")
    for url in urls {
        let backend = config.backend(for: url)
        let isBili = URLExtractor.isBilibiliHost(url)
        print("\(isBili ? "B 站" : "其它")  \(url)")
        print("  后端 → \(backend.displayName)")
        switch backend {
        case .yutto:
            if let binary = Subprocess.lookupOnPATH(config.yutto.binary) {
                let argv = YuttoArgs.build(
                    config: config.yutto, url: url, downloadDir: downloadDir, workDir: nil,
                    authFileExists: AuthFile.exists(path: config.yutto.authFile), binaryPath: binary
                )
                print("  命令 → \(argv.joined(separator: " "))")
            } else {
                print("  命令 → ⚠️ 找不到 yutto 可执行文件")
            }
        case .downie:
            let scheme = DownieBackend.schemeURL(config: config.downie, url: url, downloadDir: downloadDir)
            if let appPath = DownieBackend.resolveAppPath(configured: config.downie.appName) {
                print("  命令 → open -a \"\(appPath)\" \"\(scheme)\"")
            } else {
                print("  命令 → ⚠️ 找不到应用「\(config.downie.appName)」，请在设置里改成应用名或 .app 路径")
            }
        }
        print("")
    }
}

func downloadTest(_ url: String, extra: [String] = []) async {
    let config = AppConfig()
    let downloadDir = AppIdentity.expand(config.downloadDir)
    try? FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
    let workDir = (AppIdentity.workDirectory as NSString).appendingPathComponent("ctl-test")
    try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: workDir) }

    var yuttoConfig = config.yutto
    yuttoConfig.extraArgs += extra

    print("路由后端: \(config.backend(for: url).displayName)（B 站？\(URLExtractor.isBilibiliHost(url) ? "是" : "否")）")
    print("下载目录: \(downloadDir)")
    print("工作目录: \(workDir)")
    print("BV      : \(CanonicalKey.videoID(in: url) ?? "（未能解析，可能是短链）")")
    if !extra.isEmpty { print("附加参数: \(extra.joined(separator: " "))") }

    if config.backend(for: url) == .yutto, let binary = Subprocess.lookupOnPATH(yuttoConfig.binary) {
        let argv = YuttoArgs.build(
            config: yuttoConfig, url: url, downloadDir: downloadDir, workDir: workDir,
            authFileExists: AuthFile.exists(path: yuttoConfig.authFile), binaryPath: binary
        )
        print("命令    : \(argv.joined(separator: " "))")
    }
    print("")

    let backend: any DownloadBackend = config.backend(for: url) == .yutto
        ? YuttoBackend(config: yuttoConfig, downloadDir: downloadDir, timeout: TimeInterval(config.yuttoTimeout))
        : DownieBackend(config: config.downie, downloadDir: downloadDir)
    let result = await backend.download(url: url, workDir: workDir, handle: ProcessHandle()) { line in
        print("  │ \(line)")
    }

    print("")
    if result.success {
        print("成功：产出 \(result.outputs.count) 个文件")
        for output in result.outputs {
            let size = output.bytes.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "?"
            print("  \(output.path)  (\(size))")
        }
    } else {
        print("失败：\(result.errorMessage ?? "未知错误")")
        exit(1)
    }
}

func status() async {
    let config = await MainActor.run { ConfigStore().config }
    do {
        let store = try TaskStore()
        let stats = try await store.stats()
        print("=== 任务统计 ===")
        for state in TaskState.allCases {
            print("  \(state.displayName.padding(toLength: 6, withPad: " ", startingAt: 0)) \(stats[state] ?? 0)")
        }
        print("")
        print("=== 最近 10 条 ===")
        for task in try await store.recent(limit: 10) {
            print("  [\(task.state.displayName)] \(task.taskKey)  \(task.displayTitle)")
            for output in task.outputs { print("      → \(output.path)") }
            if let error = task.error, !error.isEmpty { print("      错误：\(String(error.prefix(160)))") }
        }
        print("")
        print("下载目录: \(AppIdentity.expand(config.downloadDir))")
        print("路由    : B 站 → \(config.bilibiliBackend.displayName)，其它 → \(config.otherBackend.displayName)")
        print("监听文件: \(config.watchFile.isEmpty ? "（自动发现）" : AppIdentity.expand(config.watchFile))")
    } catch {
        print("失败：\(error)")
        exit(1)
    }
}

func legacyAction(retire: Bool) async {
    let status = await LegacyService.status()
    print("当前状态：\(status.displayText)")
    let result = retire ? await LegacyService.retire() : await LegacyService.restore()
    print(result.message)
    let after = await LegacyService.status()
    print("之后状态：\(after.displayText)")
    if let pid = after.pid {
        print("PID \(pid) 是否存活：\(kill(pid, 0) == 0)")
    }
    exit(result.ok ? 0 : 1)
}

func configShow() async {
    let config = await MainActor.run { ConfigStore().config }
    if let data = try? config.encodedJSON(), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func configSet(_ key: String, _ value: String) async {
    let message = await MainActor.run { () -> String? in
        let store = ConfigStore()
        switch key {
        case "watch_file":
            store.update { $0.watchFile = value }
        case "download_dir":
            store.update { $0.downloadDir = value }
        case "poll_interval":
            guard let seconds = Int(value) else { return "poll_interval 需要整数秒" }
            store.update { $0.pollInterval = seconds }
        case "bilibili_backend":
            guard let backend = BackendKind(rawValue: value) else { return "只能是 yutto / downie" }
            store.update { $0.bilibiliBackend = backend }
        case "other_backend":
            guard let backend = BackendKind(rawValue: value) else { return "只能是 yutto / downie" }
            store.update { $0.otherBackend = backend }
        case "clipboard_monitor":
            store.update { $0.clipboardMonitor = (value == "true" || value == "1") }
        case "sessdata_override":
            store.update { $0.sessdataOverride = value }
        default:
            return "未知键：\(key)。支持 watch_file / download_dir / poll_interval / backend / clipboard_monitor / sessdata_override"
        }
        return nil
    }
    if let message {
        print(message)
        exit(1)
    }
    print("已设置 \(key) = \(value)（存于 suite \(ConfigStore.suiteName)）")
}

func usage() {
    print("""
    用法：liuyingctl <命令>

      doctor           环境自检（路径解析、依赖、SQLite）
      status           查看任务库统计与最近记录
      config show      打印当前配置
      config set K V  修改配置（watch_file / download_dir / bilibili_backend / other_backend / …）
      legacy status    只读查看旧版 Python 版的完成记录
      legacy retire    停用旧版 launchd 服务（plist 移到备份，可恢复）
      legacy restore   恢复旧版服务
      route <url…>     只打印路由决策与命令，不下载
      test <url>       直接下载一条链接（不经过采集与去重）
      bili smoke <BV>  实网 smoke：nav 密钥 + view + arc/search
      bili sign <mid>  打印一次 arc/search 的签名中间量
      bili raw <mid>   打印 arc/search 的原始响应体

    iCloud 读写必须在 .app 里跑：直接跑裸二进制时 TCC 归属终端，会 EPERM。
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case .none, "doctor":
    doctor()
case "config":
    let rest = Array(arguments.dropFirst())
    switch rest.first {
    case "show", .none:
        await configShow()
    case "set":
        guard rest.count >= 3 else {
            print("用法：liuyingctl config set <键> <值>")
            exit(1)
        }
        await configSet(rest[1], rest[2])
    default:
        print("config 支持 show / set")
        exit(1)
    }
case "route":
    let urls = Array(arguments.dropFirst())
    guard !urls.isEmpty else {
        print("用法：liuyingctl route <url> [url…]")
        exit(1)
    }
    await routeReport(urls)
case "test":
    let rest = Array(arguments.dropFirst())
    guard let url = rest.first else {
        print("用法：liuyingctl test <url> [追加给 yutto 的参数…]")
        exit(1)
    }
    await downloadTest(url, extra: Array(rest.dropFirst()))
case "status":
    await status()
case "legacy":
    switch Array(arguments.dropFirst()).first {
    case "status", .none:
        legacyStatus()
    case "retire":
        await legacyAction(retire: true)
    case "restore":
        await legacyAction(retire: false)
    default:
        print("legacy 支持 status / retire / restore")
        exit(1)
    }
case "bili":
    let rest = Array(arguments.dropFirst())
    if rest.first == "sign" {
        guard rest.count >= 2, let mid = Int64(rest[1]) else {
            print("用法：liuyingctl bili sign <mid>")
            exit(1)
        }
        await biliSign(mid)
        break
    }
    if rest.first == "raw" {
        guard rest.count >= 2, let mid = Int64(rest[1]) else {
            print("用法：liuyingctl bili raw <mid>")
            exit(1)
        }
        await biliRaw(mid)
        break
    }
    if rest.first == "find-multipage" {
        guard rest.count >= 2, let mid = Int64(rest[1]) else {
            print("用法：liuyingctl bili find-multipage <mid> [最多扫多少条]")
            exit(1)
        }
        let limit = rest.count >= 3 ? (Int(rest[2]) ?? 30) : 30
        await biliFindMultiPage(mid: mid, maxScan: limit)
        break
    }
    guard rest.first == "smoke", rest.count >= 2 else {
        print("用法：liuyingctl bili smoke <BV号>  |  bili sign <mid>")
        exit(1)
    }
    await biliSmoke(rest[1])
case "-h", "--help", "help":
    usage()
default:
    print("未知命令：\(arguments[0])")
    usage()
    exit(1)
}