import AppKit
import LiuYingCore
import SwiftUI

/// 首次启动引导：确认权限与路径、退役旧服务、可选一次性清理链接文件。
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// 只有点了「开始使用」并成功才置 true；「稍后设置」不改它。
    @Binding var didFinish: Bool

    @State private var legacyStatus: LegacyService.Status?
    @State private var retireLegacy = true
    @State private var enableLogin = true
    @State private var accessStatus: PermissionProbe.Status = .ok
    @State private var working = false
    @State private var summary: String?

    private var config: AppConfig { env.configStore.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用\(AppIdentity.displayName)")
                .font(.system(size: 26, weight: .bold))
            Text("把 iPhone 分享的 B 站链接变成下载好的视频。先确认几件事。")
                .font(AppFont.body)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    row(
                        ok: !accessStatus.isBlocking,
                        title: "iCloud 链接文件",
                        detail: accessStatus.displayText
                    ) {
                        if accessStatus.isBlocking {
                            Button("打开系统设置") { PermissionProbe.openFullDiskAccessSettings() }
                                .controlSize(.regular)
                            Button("重新检测") { Task { await probe() } }
                                .controlSize(.regular)
                        }
                    }

                    Divider()

                    row(
                        ok: !config.downloadDir.isEmpty,
                        title: "下载目录",
                        detail: env.configStore.resolvedDownloadDir
                    ) {
                        Button("选择…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.prompt = "选择"
                            if panel.runModal() == .OK, let url = panel.url {
                                env.configStore.update { $0.downloadDir = url.path }
                            }
                        }
                        .controlSize(.regular)
                    }

                    Divider()

                    row(
                        ok: BundledTool.resolveBiliDl(configured: config.biliDL.binary) != nil,
                        title: "bili-dl（内嵌）",
                        detail: BundledTool.resolveBiliDl(configured: config.biliDL.binary) ?? "找不到内嵌二进制，请重装 .app 或到设置里指定路径"
                    ) {
                        EmptyView()
                    }

                    Divider()

                    row(
                        ok: AuthFile.exists(path: config.biliDL.authFile),
                        title: "登录态（auth.toml）",
                        detail: AuthFile.exists(path: config.biliDL.authFile)
                            ? "已找到，可下载高画质"
                            : "未找到：最高 1080P，订阅追更会被风控"
                    ) {
                        EmptyView()
                    }
                }
                .padding(10)
            }

            if let legacyStatus, legacyStatus.needsRetire {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("停用旧版 Python bili-watcher 服务", isOn: $retireLegacy)
                            .font(.system(size: 13.5))
                        Text("当前状态：\(legacyStatus.displayText)。停用会终止进程并把 LaunchAgent plist 移到备份目录（可恢复）。")
                            .font(AppFont.hint)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                }
            }

            Toggle("登录时自动启动\(AppIdentity.displayName)", isOn: $enableLogin)
                .font(.system(size: 13.5))

            if let summary {
                Text(summary)
                    .font(AppFont.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("稍后设置") { skip() }
                    .disabled(working)
                Spacer()
                Button(working ? "处理中…" : (legacyStatus == nil ? "检查旧服务中…" : "开始使用")) {
                    start()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(working || legacyStatus == nil)
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 620)
        .task {
            await probe()
            legacyStatus = await LegacyService.status()
        }
    }

    private func row(
        ok: Bool, title: String, detail: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(ok ? Color.green : Color.orange)
                .accessibilityLabel(Text(ok ? "已就绪" : "需要处理"))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(AppFont.hint)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            actions()
        }
    }

    private func probe() async {
        let target = config.watchFile.trimmingCharacters(in: .whitespaces).isEmpty
            ? ICloudDiscovery.root
            : AppIdentity.expand(config.watchFile)
        accessStatus = await PermissionProbe.probeGuarded(path: target)
    }

    /// 「稍后设置」= 什么都不改：不启用登录项、不动旧服务、也不标记引导完成。
    private func skip() {
        dismiss()
    }

    /// 旧服务状态还在异步加载时不允许开始，否则会静默跳过退役，
    /// 留下新旧两个进程同时轮询同一个 links.txt。
    private func start() {
        guard legacyStatus != nil, !working else { return }
        working = true
        Task {
            var notes: [String] = []
            if enableLogin, !env.loginItem.set(true), let error = env.loginItem.errorMessage {
                notes.append(error)
            }
            if retireLegacy, let status = legacyStatus, status.needsRetire {
                let result = await LegacyService.retire()
                notes.append(result.message)
            }
            await env.engine?.start()
            await env.engine?.tickNow()
            if notes.isEmpty {
                didFinish = true
                dismiss()
            } else {
                summary = notes.joined(separator: "；")
                working = false
            }
        }
    }
}
