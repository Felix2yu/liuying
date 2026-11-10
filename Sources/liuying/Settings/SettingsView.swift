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
        // 只声明下限：写死尺寸或给 ideal/max 会让 Settings scene 把窗口锁成固定大小而拖不动。
        // 默认尺寸、可缩放性与跨启动记忆由 Scene 的 defaultSize / windowResizability
        // 和 SettingsWindowSizing 一起负责。
        .frame(minWidth: 560, minHeight: 420)
        .background(SettingsWindowSizing())
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
    @State private var accessStatus: PermissionProbe.Status = .ok
    @State private var downloadDirStatus = ""
    @State private var downloadDirIsWarning = false

    var body: some View {
        Form {
            Section("路径") {
                PathInputRow(
                    title: "监听文件",
                    placeholder: "留空自动发现",
                    text: bind(env, \.watchFile),
                    browse: .file(message: "选择快捷指令写入的 links.txt"),
                    showAutoDiscover: true,
                    autoDiscover: {
                        env.configStore.update { $0.watchFile = "" }
                        Task { await env.pushConfigToEngine() }
                    },
                    hint: discoveredHint
                )

                PathInputRow(
                    title: "下载目录",
                    placeholder: "目录路径（可含 ~）",
                    text: bind(env, \.downloadDir),
                    browse: .directory,
                    hint: downloadDirStatus,
                    hintColor: downloadDirIsWarning ? .red : .secondary
                )

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
                StepperRow(
                    title: "链接轮询间隔",
                    value: bind(env, \.pollInterval),
                    range: 5...3600,
                    step: 5
                ) { "\($0) 秒" }
                StepperRow(
                    title: "每轮最多处理",
                    value: bind(env, \.maxTasksPerRound),
                    range: 1...100,
                    step: 1
                ) { "\($0) 个" }
                StepperRow(
                    title: "订阅轮询间隔",
                    value: bind(env, \.subscriptionInterval),
                    range: 60...86_400,
                    step: 60
                ) { "\($0 / 60) 分钟" }
            }

            Section("行为") {
                Toggle("发送通知（新增、完成、失败、订阅异常）", isOn: bind(env, \.notify))
                Toggle("监听剪贴板，复制任意 http(s) 链接自动入队", isOn: bind(env, \.clipboardMonitor))
                Text("非 B 站链接会按下面的路由交给 Downie；这个开关会抓取剪贴板里的所有网址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("登录时启动", isOn: Binding(
                    get: { env.loginItem.isEnabled },
                    set: { _ = env.loginItem.set($0) }
                ))
                Text(env.loginItem.statusText).font(.caption).foregroundStyle(.secondary)
                if let loginError = env.loginItem.errorMessage {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("在 Dock 中显示\(AppIdentity.displayName)", isOn: Binding(
                    get: { DockVisibility.isEnabled },
                    set: { enabled in
                        UserDefaults.standard.set(enabled, forKey: DockVisibility.key)
                        Task { @MainActor in
                            let hasVisible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                            NSApp.setActivationPolicy(enabled || hasVisible ? .regular : .accessory)
                        }
                    }
                ))
                Text("菜单栏图标可能被系统隐藏；开启后可从 Dock 和主菜单进入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("通知") {
                LabeledContent("系统授权") {
                    HStack(spacing: 6) {
                        Text(Notifier.shared.state.displayText)
                            .font(.caption)
                            .foregroundStyle(
                                Notifier.shared.state == .authorized ? Color.secondary : Color.orange
                            )
                        Button("重新检测") {
                            Task { await Notifier.shared.refreshAuthorization() }
                        }
                        Button("请求授权") {
                            Task { await Notifier.shared.requestAuthorizationIfNeeded() }
                        }
                        Button("打开系统设置") { Notifier.shared.openNotificationSettings() }
                    }
                    .controlSize(.small)
                }
                Text("通知开关只决定要不要发；系统侧关掉授权时这里也不会弹通知。改完系统设置后点「重新检测」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            env.loginItem.refresh()
            refreshDownloadDirStatus()
            Task {
                await probe()
                await Notifier.shared.refreshAuthorization()
            }
        }
        .onChange(of: env.configStore.config.downloadDir) { _, _ in
            refreshDownloadDirStatus()
        }
    }

    private var discoveredHint: String {
        let configured = env.configStore.config.watchFile
        if configured.trimmingCharacters(in: .whitespaces).isEmpty {
            return "自动发现：\(env.model.snapshot.linkStatusText)"
        }
        return "解析为：\(AppIdentity.expand(configured))"
    }

    private func refreshDownloadDirStatus() {
        let entered = env.configStore.config.downloadDir
        let path = env.configStore.resolvedDownloadDir
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let resolvedNote = path != entered ? "解析为：\(path)" : nil
        if entered.trimmingCharacters(in: .whitespaces).isEmpty {
            downloadDirStatus = "留空将使用默认目录：\(path)"
            downloadDirIsWarning = false
        } else if !exists {
            downloadDirStatus = "目录还不存在，首次下载时会自动创建：\(path)"
            downloadDirIsWarning = false
        } else if !isDirectory.boolValue {
            downloadDirStatus = "这个路径是文件而不是目录：\(path)"
            downloadDirIsWarning = true
        } else if !FileManager.default.isWritableFile(atPath: path) {
            downloadDirStatus = "目录不可写，请检查权限：\(path)"
            downloadDirIsWarning = true
        } else {
            downloadDirStatus = resolvedNote ?? "目录存在且可写"
            downloadDirIsWarning = false
        }
    }

    private func probe() async {
        let configured = env.configStore.config.watchFile
        let target = configured.trimmingCharacters(in: .whitespaces).isEmpty
            ? ICloudDiscovery.root
            : AppIdentity.expand(configured)
        accessStatus = await PermissionProbe.probeGuarded(path: target)
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
                PathInputRow(
                    title: "yutto",
                    placeholder: "yutto 或绝对路径",
                    text: bind(env, \.yutto.binary),
                    browse: .file(message: "选择 yutto 可执行文件")
                )
                let resolved = Subprocess.lookupOnPATH(env.configStore.config.yutto.binary)
                Text(resolved.map { "解析为：\($0)" } ?? "找不到这个可执行文件")
                    .font(.caption)
                    .foregroundStyle(resolved == nil ? Color.red : Color.secondary)
            }

            Section("画质与编码") {
                LabeledPicker(
                    title: "视频画质上限",
                    selection: bind(env, \.yutto.videoQuality),
                    options: YuttoQuality.videoOptions.map {
                        PickerOption(id: $0.value, label: "\($0.value) · \($0.label)")
                    }
                )
                LabeledPicker(
                    title: "音频码率",
                    selection: bind(env, \.yutto.audioQuality),
                    options: YuttoQuality.audioOptions.map {
                        PickerOption(id: $0.value, label: "\($0.value) · \($0.label)")
                    }
                )
                LabeledTextField(
                    title: "vcodec（下载:保存）",
                    placeholder: "下载:保存",
                    text: bind(env, \.yutto.vcodec)
                )
                LabeledTextField(
                    title: "编码优先级",
                    placeholder: "av1,hevc,avc",
                    text: $priorityText,
                    hint: "必须包含全部三种，否则未列出的编码永远不会被选中",
                    onSubmit: commitPriority
                )
                LabeledPicker(
                    title: "yutto 输出格式",
                    selection: bind(env, \.yutto.outputFormat),
                    options: YuttoQuality.outputFormats.map { PickerOption(id: $0, label: $0) }
                )
                LabeledTextField(
                    title: "目录模板",
                    placeholder: "例如 {owner}/{title}",
                    text: bind(env, \.yutto.subpathTemplate)
                )
            }

            Section("资源") {
                Toggle("下载全部分 P（--batch）", isOn: bind(env, \.yutto.downloadAllPages))
                Toggle("生成弹幕", isOn: bind(env, \.yutto.downloadDanmaku))
                Toggle("生成字幕", isOn: bind(env, \.yutto.downloadSubtitle))
                Toggle("单独保存封面", isOn: bind(env, \.yutto.saveCover))
            }

            Section("登录态") {
                PathInputRow(
                    title: "auth.toml",
                    placeholder: "auth.toml 路径（可含 ~）",
                    text: bind(env, \.yutto.authFile),
                    browse: .file(message: "选择 yutto 的 auth.toml")
                )
                LabeledTextField(
                    title: "profile",
                    placeholder: "默认 profile 名",
                    text: bind(env, \.yutto.authProfile)
                )
                let exists = AuthFile.exists(path: env.configStore.config.yutto.authFile)
                Label(
                    exists ? "文件存在，会带上 --auth-file" : "文件不存在，将退化为未登录（最高 1080P）",
                    systemImage: exists ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(exists ? Color.secondary : Color.red)
            }

            Section("容器规整") {
                Text("下载后按视频编码 remux 到目标容器；无损音轨装不进 mp4/mov 时自动退回 mkv。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(["av1", "hevc", "avc"], id: \.self) { codec in
                    LabeledPicker(
                        title: codec,
                        selection: Binding(
                            get: { env.configStore.config.yutto.outputContainers[codec] ?? "mkv" },
                            set: { newValue in
                                env.configStore.update { $0.yutto.outputContainers[codec] = newValue }
                                Task { await env.pushConfigToEngine() }
                            }
                        ),
                        options: YuttoQuality.containers.map { PickerOption(id: $0, label: $0) }
                    )
                }
            }

            Section("其它") {
                LabeledTextField(
                    title: "追加参数",
                    placeholder: "--proxy auto",
                    text: $extraArgsText,
                    hint: "原样追加到 yutto 命令末尾",
                    onSubmit: commitExtraArgs
                )
                StepperRow(
                    title: "单次下载超时",
                    value: bind(env, \.yuttoTimeout),
                    range: 60...86_400,
                    step: 60
                ) { "\($0 / 60) 分钟" }
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
                Text("B 站主机（b23.tv / bilibili.com / bilibili.tv）走第一个；其余 http(s) 链接走第二个 —— yutto 只认 B 站。后端在任务开始下载时按当前设置选择，排队中的任务改设置后会跟着换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Downie") {
                LabeledTextField(
                    title: "应用名",
                    placeholder: "如 Downie 4",
                    text: bind(env, \.downie.appName)
                )
                LabeledPicker(
                    title: "后处理",
                    selection: bind(env, \.downie.postprocessing),
                    options: YuttoQuality.downiePostprocessing.map { PickerOption(id: $0, label: $0) }
                )
                PathInputRow(
                    title: "目标目录",
                    placeholder: "留空用下载目录",
                    text: bind(env, \.downie.destination),
                    browse: .directory
                )
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