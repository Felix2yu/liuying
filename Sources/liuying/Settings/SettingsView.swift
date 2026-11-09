import AppKit
import LiuYingCore
import SwiftUI

/// 设置：四个单页 tab，不做编辑锁。
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TabView {
            PathsPane().environment(env)
                .tabItem { Label("通用", systemImage: "gearshape") }
            YuttoPane().environment(env)
                .tabItem { Label("yutto", systemImage: "terminal") }
            DowniePane().environment(env)
                .tabItem { Label("Downie", systemImage: "arrow.down.app") }
            AdvancedPane().environment(env)
                .tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 620, height: 560)
    }
}

/// 配置绑定：写回 ConfigStore 并立刻推给引擎（轮询间隔、路径都要即时生效）。
@MainActor
func bind<T>(_ env: AppEnvironment, _ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
    Binding(
        get: { env.configStore.config[keyPath: keyPath] },
        set: { value in
            env.configStore.update { $0[keyPath: keyPath] = value }
            Task { await env.pushConfigToEngine() }
        }
    )
}

// MARK: - 通用

struct PathsPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var accessStatus: PermissionProbe.Status = .ok

    var body: some View {
        Form {
            Section("路径") {
                LabeledContent("监听文件") {
                    HStack(spacing: 6) {
                        TextField("留空自动发现", text: bind(env, \.watchFile))
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseFile(into: \.watchFile) }
                        Button("自动发现") {
                            env.configStore.update { $0.watchFile = "" }
                            Task { await env.pushConfigToEngine() }
                        }
                    }
                }
                Text(discoveredHint).font(.caption).foregroundStyle(.secondary)

                LabeledContent("下载目录") {
                    HStack(spacing: 6) {
                        TextField("~/Downloads/Bilibili", text: bind(env, \.downloadDir))
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseDirectory(into: \.downloadDir) }
                    }
                }

                LabeledContent("iCloud 访问") {
                    HStack(spacing: 6) {
                        Text(accessStatus.displayText)
                            .font(.caption)
                            .foregroundStyle(accessStatus.isBlocking ? Color.red : Color.secondary)
                        Button("重新检测") { Task { await probe() } }
                        if accessStatus.isBlocking {
                            Button("打开系统设置") { PermissionProbe.openFullDiskAccessSettings() }
                        }
                    }
                }
            }

            Section("轮询") {
                Stepper(value: bind(env, \.pollInterval), in: 5...3600, step: 5) {
                    Text("链接轮询间隔：\(env.configStore.config.pollInterval) 秒")
                }
                Stepper(value: bind(env, \.maxTasksPerRound), in: 1...100) {
                    Text("每轮最多处理：\(env.configStore.config.maxTasksPerRound) 个")
                }
                Stepper(
                    value: bind(env, \.subscriptionInterval),
                    in: 60...86_400,
                    step: 60
                ) {
                    Text("订阅轮询间隔：\(env.configStore.config.subscriptionInterval / 60) 分钟")
                }
            }

            Section("行为") {
                Toggle("下载完成/失败时发送通知", isOn: bind(env, \.notify))
                Toggle("监听剪贴板，复制 B 站链接自动入队", isOn: bind(env, \.clipboardMonitor))
                Toggle("登录时启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        if let error = LoginItem.setEnabled(value) {
                            loginError = error
                            return
                        }
                        launchAtLogin = value
                        loginError = nil
                    }
                ))
                Text(LoginItem.statusText).font(.caption).foregroundStyle(.secondary)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            Task { await probe() }
        }
    }

    private var discoveredHint: String {
        let configured = env.configStore.config.watchFile
        if configured.trimmingCharacters(in: .whitespaces).isEmpty {
            return "自动发现：\(env.model.snapshot.linkStatusText)"
        }
        return "解析为：\(AppIdentity.expand(configured))"
    }

    private func probe() async {
        let configured = env.configStore.config.watchFile
        let target = configured.trimmingCharacters(in: .whitespaces).isEmpty
            ? ICloudDiscovery.root
            : AppIdentity.expand(configured)
        accessStatus = await PermissionProbe.probeGuarded(path: target)
    }

    private func chooseFile(into keyPath: WritableKeyPath<AppConfig, String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择快捷指令写入的 links.txt"
        if panel.runModal() == .OK, let url = panel.url {
            env.configStore.update { $0[keyPath: keyPath] = url.path }
            Task { await env.pushConfigToEngine() }
        }
    }

    private func chooseDirectory(into keyPath: WritableKeyPath<AppConfig, String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            env.configStore.update { $0[keyPath: keyPath] = url.path }
            Task { await env.pushConfigToEngine() }
        }
    }
}

// MARK: - yutto

struct YuttoPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var priorityText = ""
    @State private var extraArgsText = ""

    var body: some View {
        Form {
            Section("可执行文件") {
                LabeledContent("yutto") {
                    HStack(spacing: 6) {
                        TextField("yutto 或绝对路径", text: bind(env, \.yutto.binary))
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseExecutable() }
                    }
                }
                let resolved = Subprocess.lookupOnPATH(env.configStore.config.yutto.binary)
                Text(resolved.map { "解析为：\($0)" } ?? "⚠️ 找不到这个可执行文件")
                    .font(.caption)
                    .foregroundStyle(resolved == nil ? Color.red : Color.secondary)
            }

            Section("画质与编码") {
                Picker("视频画质上限", selection: bind(env, \.yutto.videoQuality)) {
                    ForEach(YuttoQuality.videoOptions, id: \.value) { option in
                        Text("\(option.value) · \(option.label)").tag(option.value)
                    }
                }
                Picker("音频码率", selection: bind(env, \.yutto.audioQuality)) {
                    ForEach(YuttoQuality.audioOptions, id: \.value) { option in
                        Text("\(option.value) · \(option.label)").tag(option.value)
                    }
                }
                TextField("vcodec（下载:保存）", text: bind(env, \.yutto.vcodec))
                LabeledContent("编码优先级") {
                    TextField("av1,hevc,avc", text: $priorityText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitPriority() }
                }
                Text("必须包含全部三种，否则未列出的编码永远不会被选中").font(.caption).foregroundStyle(.secondary)
                Picker("yutto 输出格式", selection: bind(env, \.yutto.outputFormat)) {
                    ForEach(YuttoQuality.outputFormats, id: \.self) { Text($0).tag($0) }
                }
                TextField("目录模板", text: bind(env, \.yutto.subpathTemplate))
            }

            Section("资源") {
                Toggle("下载全部分 P（--batch）", isOn: bind(env, \.yutto.downloadAllPages))
                Toggle("生成弹幕", isOn: bind(env, \.yutto.downloadDanmaku))
                Toggle("生成字幕", isOn: bind(env, \.yutto.downloadSubtitle))
                Toggle("单独保存封面", isOn: bind(env, \.yutto.saveCover))
            }

            Section("登录态") {
                LabeledContent("auth.toml") {
                    HStack(spacing: 6) {
                        TextField("~/.config/yutto/auth.toml", text: bind(env, \.yutto.authFile))
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseAuthFile() }
                    }
                }
                TextField("profile", text: bind(env, \.yutto.authProfile))
                let exists = AuthFile.exists(path: env.configStore.config.yutto.authFile)
                Text(exists ? "✅ 文件存在，会带上 --auth-file" : "⚠️ 文件不存在，将退化为未登录（最高 1080P）")
                    .font(.caption)
                    .foregroundStyle(exists ? Color.secondary : Color.red)
            }

            Section("容器规整") {
                Text("下载后按视频编码 remux 到目标容器；无损音轨装不进 mp4/mov 时自动退回 mkv。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(["av1", "hevc", "avc"], id: \.self) { codec in
                    Picker(codec, selection: Binding(
                        get: { env.configStore.config.yutto.outputContainers[codec] ?? "mkv" },
                        set: { newValue in
                            env.configStore.update { $0.yutto.outputContainers[codec] = newValue }
                            Task { await env.pushConfigToEngine() }
                        }
                    )) {
                        ForEach(YuttoQuality.containers, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section("其它") {
                LabeledContent("追加参数") {
                    TextField("--proxy auto", text: $extraArgsText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitExtraArgs() }
                }
                Text("原样追加到 yutto 命令末尾").font(.caption).foregroundStyle(.secondary)
                Stepper(value: bind(env, \.yuttoTimeout), in: 60...86_400, step: 60) {
                    Text("单次下载超时：\(env.configStore.config.yuttoTimeout / 60) 分钟")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            priorityText = env.configStore.config.yutto.vcodecPriority.joined(separator: ",")
            extraArgsText = ShellWord.join(env.configStore.config.yutto.extraArgs)
        }
    }

    private func commitPriority() {
        let values = priorityText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return }
        env.configStore.update { $0.yutto.vcodecPriority = values }
        Task { await env.pushConfigToEngine() }
    }

    private func commitExtraArgs() {
        guard let words = ShellWord.split(extraArgsText) else {
            Log.warning("追加参数引号未闭合，未保存")
            return
        }
        env.configStore.update { $0.yutto.extraArgs = words }
        Task { await env.pushConfigToEngine() }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            env.configStore.update { $0.yutto.binary = url.path }
            Task { await env.pushConfigToEngine() }
        }
    }

    private func chooseAuthFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "选择"
        panel.message = "选择 yutto 的 auth.toml"
        if panel.runModal() == .OK, let url = panel.url {
            env.configStore.update { $0.yutto.authFile = url.path }
            Task { await env.pushConfigToEngine() }
        }
    }
}

// MARK: - Downie

struct DowniePane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section("使用前必做（Downie 侧设置）") {
                Text("`downie://` 只支持 url / postprocessing / destination / action / title 五个参数，**没有**「立刻开始下载」的参数。能不能自动开始，取决于下面的开关。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("设置 → 高级 → 开启「自动化模式」：否则会弹质量/字幕对话框等待操作，下载不会自动开始", systemImage: "1.circle")
                Label("在 Downie 内登录 B 站：它不共享浏览器登录态，未登录只能拿低画质", systemImage: "2.circle")
                Label("设置 → 通用 → 勾选「Use MP4 container for AV1」", systemImage: "3.circle")
                Label("设置 → 通用 → 质量选「分辨率上限」：选「每次询问」会每次弹格式框", systemImage: "4.circle")
                Button("打开 Downie 去设置") { openDownie() }
                    .controlSize(.small)
                    .disabled(DownieBackend.resolveAppPath(configured: env.configStore.config.downie.appName) == nil)
            }

            Section("路由") {
                Picker("B 站链接", selection: bind(env, \.bilibiliBackend)) {
                    ForEach(BackendKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Picker("其它链接", selection: bind(env, \.otherBackend)) {
                    ForEach(BackendKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text("B 站主机（b23.tv / bilibili.com / bilibili.tv）走第一个；其余 http(s) 链接走第二个 —— yutto 只认 B 站。路由在入队时确定，下载过程中不会换后端。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Downie") {
                TextField("应用名", text: bind(env, \.downie.appName))
                Picker("后处理", selection: bind(env, \.downie.postprocessing)) {
                    ForEach(YuttoQuality.downiePostprocessing, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("目标目录") {
                    HStack(spacing: 6) {
                        TextField("留空用下载目录", text: bind(env, \.downie.destination))
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.prompt = "选择"
                            if panel.runModal() == .OK, let url = panel.url {
                                env.configStore.update { $0.downie.destination = url.path }
                                Task { await env.pushConfigToEngine() }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openDownie() {
        guard let path = DownieBackend.resolveAppPath(configured: env.configStore.config.downie.appName) else {
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}