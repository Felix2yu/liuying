import AppKit
import LiuYingCore
import SwiftUI
import UniformTypeIdentifiers

/// 导入 Downie 的下载记录。
///
/// 只读**用户选中的导出文件**，不碰 Downie 的沙盒容器：后者受 TCC 保护、
/// 格式未文档化、还会随 iCloud 同步变化。打开面板选中的文件由系统自动授权访问。
struct ImportDownieSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var fileName: String?
    @State private var document: DownieImportDocument?
    @State private var errorMessage: String?
    @State private var result: DownieImportResult?
    @State private var importedIDs: [Int64] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导入 Downie 下载记录").font(.headline)
            Text("在 Downie 里打开「窗口 → 显示历史记录」，用工具栏的导出功能得到 Downie History Export.xml（可以不带预览图）。也支持 Downie 的 CSV、XML 导入格式和纯链接清单。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("选择文件…") { chooseFile() }
                    .disabled(busy)
                if let fileName {
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let document { preview(document) }
            if let result { summary(result) }

            Text("只导入原始页面链接与标题，登记为「已完成」记录，不会重新下载、不会删除 links.txt。画质、字幕、后处理、预览图和本地文件路径都不导入；需要重下可在队列里点「重新下载」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if result != nil {
                    Button("撤销本次导入") { undo() }
                        .disabled(busy || importedIDs.isEmpty)
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button("取消") { dismiss() }
                    Button(busy ? "导入中…" : importButtonTitle) { startImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || document == nil)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 460, idealWidth: 560)
    }

    private var importButtonTitle: String {
        guard let document else { return "导入" }
        return "导入 \(document.records.count) 条"
    }

    private func preview(_ document: DownieImportDocument) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("已识别：\(document.format.displayName)，\(document.records.count) 条链接"
                 + (document.skipped > 0 ? "，另有 \(document.skipped) 条没有可用链接" : ""))
                .font(.callout)
            Text("重复记录与已有任务会在导入时自动跳过，并在下方列出明细。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveTint(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func summary(_ result: DownieImportResult) -> some View {
        Text("共 \(result.scanned) 条：新增 \(result.imported) 条，文件内重复 \(result.duplicatesInFile) 条，"
             + "对应任务已存在 \(result.alreadyExists) 条。")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 Downie 历史导出 XML / CSV / TXT 文件"
        panel.prompt = "选择"
        panel.allowedContentTypes = ["xml", "plist", "csv", "txt", "text"]
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            switch DownieHistoryImporter.parse(data: data, fileName: url.lastPathComponent) {
            case .success(let parsed):
                document = parsed
                fileName = url.lastPathComponent
                errorMessage = nil
                result = nil
                importedIDs = []
            case .failure(let error):
                document = nil
                fileName = url.lastPathComponent
                errorMessage = error.message
            }
        } catch {
            document = nil
            fileName = url.lastPathComponent
            errorMessage = "读取失败：\(error.localizedDescription)"
        }
    }

    private func startImport() {
        guard let engine = env.engine else {
            errorMessage = "引擎还没启动完成"
            return
        }
        guard let records = document?.records, !records.isEmpty else { return }
        busy = true
        let input = records
        Task { @MainActor in
            let outcome = await engine.importDownieRecords(input)
            busy = false
            if let failure = outcome.failure {
                errorMessage = "导入失败：\(failure)"
                return
            }
            result = outcome
            importedIDs = outcome.importedIDs
            errorMessage = nil
            env.feedback.show("已导入 \(outcome.imported) 条 Downie 记录")
        }
    }

    private func undo() {
        guard let engine = env.engine, !importedIDs.isEmpty else { return }
        busy = true
        let ids = importedIDs
        Task { @MainActor in
            let removed = await engine.undoImport(taskIDs: ids)
            busy = false
            importedIDs = []
            result = nil
            errorMessage = removed > 0
                ? "已撤销 \(removed) 条导入记录"
                : "没有可撤销的记录"
        }
    }
}
