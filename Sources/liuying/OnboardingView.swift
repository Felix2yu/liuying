import AppKit
import LiuYingCore
import SwiftUI

/// 首次启动引导：确认权限与路径、退役旧服务、可选一次性清理链接文件。
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var legacyStatus: LegacyService.Status?
    @State private var retireLegacy = true
    @State private var enableLogin = true
    @State private var accessStatus: PermissionProbe.Status = .ok
    @State private var working = false
    @State private var summary: String?

    private var config: AppConfig { env.configStore.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("欢迎使用\(AppIdentity.displayName)")
                .font(.title3.weight(.semibold))
            Text("把 iPhone 分享的 B 站链接变成下载好的视频。先确认几件事。")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    row(
                        ok: !accessStatus.isBlocking,
                        title: "iCloud 链接文件",
                        detail: accessStatus.displayText
                    ) {
                        if accessStatus.isBlocking {
                            Button("打开系统设置") { PermissionProbe.openFullDiskAccessSettings() }
                                .controlSize(.small)
                            Button("重新检测") { Task { await probe() } }.controlSize(.small)
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
                        .controlSize(.small)
                    }

                    Divider()

                    row(
                        ok: Subprocess.lookupOnPATH(config.yutto.binary) != nil,
                        title: "yutto",
                        detail: Subprocess.lookupOnPATH(config.yutto.binary) ?? "找不到可执行文件，请到设置里指定"
                    ) {
                        EmptyView()
                    }

                    Divider()

                    row(
                        ok: AuthFile.exists(path: config.yutto.authFile),
                        title: "登录态（auth.toml）",
                        detail: AuthFile.exists(path: config.yutto.authFile)
                            ? "已找到，可下载高画质"
                            : "未找到：最高 1080P，订阅追更会被风控"
                    ) {
                        EmptyView()
                    }
                }
                .padding(8)
            }

            if let legacyStatus, legacyStatus.needsRetire {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("停用旧版 Python bili-watcher 服务", isOn: $retireLegacy)
                        Text("当前状态：\(legacyStatus.displayText)。停用会终止进程并把 LaunchAgent plist 移到备份目录（可恢复）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }

            Toggle("登录时自动启动\(AppIdentity.displayName)", isOn: $enableLogin)
                .font(.callout)

            if let summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("稍后设置") { finish(skipLegacy: true) }
                Spacer()
                Button(working ? "处理中…" : "开始使用") { finish(skipLegacy: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            await probe()
            legacyStatus = await LegacyService.status()
        }
    }

    private func row(
        ok: Bool, title: String, detail: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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

    private func finish(skipLegacy: Bool) {
        working = true
        Task {
            var notes: [String] = []
            if enableLogin, let error = LoginItem.setEnabled(true) {
                notes.append(error)
            }
            if !skipLegacy, retireLegacy,
               let status = legacyStatus, status.needsRetire {
                let result = await LegacyService.retire()
                notes.append(result.message)
            }
            await env.engine?.start()
            await env.engine?.tickNow()
            if notes.isEmpty {
                dismiss()
            } else {
                summary = notes.joined(separator: "；")
                working = false
            }
        }
    }
}