import AppKit
import LiuYingCore
import SwiftUI

/// 高级：日志/数据目录、SESSDATA、旧版服务退役、一次性清理链接文件。
struct AdvancedPane: View {
    @Environment(AppEnvironment.self) private var env

    @State private var legacyStatus: LegacyService.Status?
    @State private var legacyMessage: String?
    @State private var showRetireConfirm = false
    @State private var showRestoreConfirm = false
    @State private var working = false

    @State private var prunePreview: LinkFilePruner.Preview?
    @State private var pruneMessage: String?
    @State private var showPruneConfirm = false

    var body: some View {
        Form {
            Section("诊断") {
                HStack(spacing: 8) {
                    Button("查看日志") {
                        NSWorkspace.shared.selectFile(Log.logFilePath, inFileViewerRootedAtPath: "")
                    }
                    Button("打开数据目录") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: AppIdentity.supportDirectory))
                    }
                    Button("打开备份") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: AppIdentity.backupsDirectory))
                    }
                }
                .controlSize(.small)
            }

            Section("登录态") {
                SecureField("手动覆盖 SESSDATA（留空则读 auth.toml）", text: bind(env, \.sessdataOverride))
                let resolved = AuthFile.resolveSessdata(
                    override: env.configStore.config.sessdataOverride,
                    path: env.configStore.config.yutto.authFile,
                    profile: env.configStore.config.yutto.authProfile
                )
                Text(resolved == nil ? "⚠️ 当前没有可用的 SESSDATA：订阅追更会被风控" : "✅ 已就绪（不显示内容）")
                    .font(.caption)
                    .foregroundStyle(resolved == nil ? Color.red : Color.secondary)
            }

            Section("旧版 Python 服务") {
                HStack(spacing: 8) {
                    Text(legacyStatus?.displayText ?? "检查中…")
                    Spacer()
                    Button("重新检查") { Task { await refreshLegacy() } }
                        .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button("停用旧服务…") { showRetireConfirm = true }
                        .disabled(working || !(legacyStatus?.needsRetire ?? false))
                    Button("恢复旧服务") { showRestoreConfirm = true }
                        .disabled(working || legacyStatus?.plistInstalled ?? true)
                }
                .controlSize(.small)

                if let legacyMessage {
                    Text(legacyMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("停用 = 停止进程 + 把 LaunchAgent plist 移到备份目录（可恢复），不会再开机自启。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("链接文件清理") {
                Text("下载成功后会自动把已消费的链接从 links.txt 里删掉。这里是一次性清理：用旧版已完成记录清一遍，其余行逐字节保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("预览并清理…") { preparePrune() }
                    .controlSize(.small)
                if let pruneMessage {
                    Text(pruneMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshLegacy() }
        .confirmationDialog(
            "停用旧版 Python 服务？",
            isPresented: $showRetireConfirm,
            titleVisibility: .visible
        ) {
            Button("停用", role: .destructive) { retireLegacy() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会执行 launchctl bootout，并把 LaunchAgent 的 plist 移到备份目录。之后 \(AppIdentity.displayName) 接管轮询。")
        }
        .confirmationDialog(
            "恢复旧版服务？",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复") { restoreLegacy() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧服务恢复后会和 \(AppIdentity.displayName) 同时轮询同一个 links.txt，可能重复下载。")
        }
        .confirmationDialog(
            "从 links.txt 移除已下载的链接？",
            isPresented: $showPruneConfirm,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) { applyPrune() }
            Button("取消", role: .cancel) {}
        } message: {
            if let preview = prunePreview {
                Text("将移除 \(preview.removedLines) 行、改写 \(preview.modifiedLines) 行，共 \(preview.removedURLs) 个链接；文件共 \(preview.totalLines) 行，其余保持不变。会先备份。")
            } else {
                Text("没有可清理的内容。")
            }
        }
    }

    private func refreshLegacy() async {
        legacyStatus = await LegacyService.status()
    }

    private func retireLegacy() {
        working = true
        Task {
            let result = await LegacyService.retire()
            legacyMessage = result.message
            await refreshLegacy()
            working = false
        }
    }

    private func restoreLegacy() {
        working = true
        Task {
            let result = await LegacyService.restore()
            legacyMessage = result.message
            await refreshLegacy()
            working = false
        }
    }

    private func preparePrune() {
        Task {
            let consumed = LegacyReader.completedKeys()
            let path = await env.engine?.linkFilePath() ?? ICloudDiscovery.placeholderPath
            prunePreview = await LinkFilePruner.preview(path: path, consumed: consumed)
            if let preview = prunePreview, preview.changed {
                showPruneConfirm = true
            } else {
                pruneMessage = "没有需要清理的链接（旧版完成记录：\(consumed.count) 个键）"
            }
        }
    }

    private func applyPrune() {
        Task {
            let consumed = LegacyReader.completedKeys()
            let path = await env.engine?.linkFilePath() ?? ICloudDiscovery.placeholderPath
            let result = await LinkFilePruner.apply(
                path: path, consumed: consumed, backupDirectory: AppIdentity.backupsDirectory
            )
            if result.applied, let preview = result.preview {
                pruneMessage = "已清理 \(preview.removedURLs) 个链接（\(preview.removedLines) 行），备份：\(result.backupPath ?? "无")"
            } else {
                pruneMessage = result.reason ?? "未执行"
            }
            await env.engine?.refreshLinkStatus()
        }
    }
}