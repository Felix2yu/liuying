import AppKit
import LiuYingCore
import SwiftUI

/// 队列：紧凑列表 + 行内展开日志与操作。
struct QueueScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedID: Int64?
    @State private var stateFilter: TaskState?
    @State private var pendingRemoval: Int64?

    private var snapshot: EngineSnapshot { env.model.snapshot }

    private var filtered: [DownloadTask] {
        let keyword = state.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return snapshot.recent.filter { task in
            if let stateFilter, task.state != stateFilter { return false }
            guard !keyword.isEmpty else { return true }
            return task.displayTitle.lowercased().contains(keyword)
                || (task.ownerName ?? "").lowercased().contains(keyword)
        }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("全部", selected: stateFilter == nil, count: snapshot.recent.count) {
                            stateFilter = nil
                        }
                        ForEach(TaskState.allCases, id: \.self) { state in
                            chip(
                                state.displayName,
                                selected: stateFilter == state,
                                count: snapshot.recent.filter { $0.state == state }.count
                            ) { stateFilter = state }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            Section {
                if filtered.isEmpty {
                    Text("队列是空的。从 iPhone 分享链接，或在菜单里「添加链接…」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(filtered) { task in
                        row(task)
                            .id("task:\(task.id)")
                    }
                }
            } header: {
                Text(snapshot.statusLine).font(.caption).foregroundStyle(.secondary)
            }

            if snapshot.recentTruncated {
                Section {
                    Button("加载更多历史（当前 \(snapshot.recentLimit) 条）") {
                        Task { await env.engine?.showMoreHistory() }
                    }
                    .controlSize(.small)
                }
            }
        }
        .listStyle(.inset)
        // 展开当前下载中的任务时，每秒刷新一次快照以显示实时日志。
        .task(id: expandedID) {
            guard expandedID != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await env.engine?.refreshSnapshot()
            }
        }
        .onChange(of: state.selectedTab) { _, tab in
            if tab == .queue { Task { await env.engine?.refreshSnapshot() } }
        }
        .confirmationDialog(
            "从队列移除这条任务？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                guard let id = pendingRemoval else { return }
                pendingRemoval = nil
                expandedID = nil
                Task { await env.engine?.remove(taskID: id) }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("只移除队列记录，不删除已下载的文件；去重键会释放，之后再贴同一链接会重新下载。")
        }
    }

    private func chip(_ title: String, selected: Bool, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(minHeight: 20)
                .chipBackground(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ task: DownloadTask) -> some View {
        let expanded = expandedID == task.id
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    expandedID = expanded ? nil : task.id
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(color(for: task.state))
                        .frame(width: 7, height: 7)
                        .offset(y: -1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.displayTitle)
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(metaLine(task))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(task.source.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(expanded ? "已展开" : "已折叠"))

            if expanded {
                detail(task).transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(.vertical, 3)
    }

    private func detail(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.rawURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            if let error = task.error, !error.isEmpty {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .adaptiveTint(.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            ForEach(task.outputs) { output in
                HStack(spacing: 6) {
                    Image(systemName: "film").font(.caption2).foregroundStyle(.tertiary)
                    Text(output.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("显示") {
                        NSWorkspace.shared.selectFile(output.path, inFileViewerRootedAtPath: "")
                    }
                    .controlSize(.small)
                }
            }

            if snapshot.currentTaskID == task.id {
                logView
            }

            HStack(spacing: 6) {
                if task.state == .sent {
                    Button("已下载，标记完成") {
                        Task { await env.engine?.confirm(taskID: task.id) }
                    }
                }
                if task.state == .failed || task.state == .done
                    || task.state == .cancelled || task.state == .sent {
                    Button("重新下载") {
                        Task { await env.engine?.retry(taskID: task.id) }
                    }
                }
                if task.state == .downloading {
                    Button("取消当前") {
                        Task { await env.engine?.cancelCurrentDownload() }
                    }
                }
                Button("复制链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.rawURL, forType: .string)
                }
                Spacer()
                Button("移除…", role: .destructive) { pendingRemoval = task.id }
                    .disabled(task.state == .downloading)
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private var logView: some View {
        ScrollView {
            Text(snapshot.currentLog.suffix(120).joined(separator: "\n"))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 160)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func metaLine(_ task: DownloadTask) -> String {
        var parts = [task.state.displayName]
        if task.attempts > 1 { parts.append("第 \(task.attempts) 次") }
        if let next = task.nextRetryAt, next > Date() {
            parts.append("\(next.formatted(date: .abbreviated, time: .shortened)) 后重试")
        }
        if task.state == .sent { parts.append("进度请在 Downie 里查看") }
        if let owner = task.ownerName { parts.append(owner) }
        parts.append(task.updatedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private func color(for state: TaskState) -> Color {
        switch state {
        case .pending: .secondary
        case .downloading: .accentColor
        case .done: .green
        case .failed: .red
        case .cancelled: .secondary
        case .sent: .orange
        }
    }

}

/// 手动添加链接。
struct AddLinkSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var message: String?
    @State private var busy = false
    @State private var addedIDs: [Int64] = []
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加链接").font(.headline)
            Text("粘贴分享文案、BV 号链接或 b23.tv 短链，一行一条。也可以直接把链接拖进来。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 140)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .dropDestination(for: String.self) { items, _ in
                    text += (text.isEmpty ? "" : "\n") + items.joined(separator: "\n")
                    return true
                }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if finished {
                    Button("撤销本次添加") { undo() }
                        .disabled(busy)
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button("取消") { dismiss() }
                    Button(busy ? "添加中…" : "添加到队列") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 420, idealWidth: 520)
    }

    private func add() {
        guard let engine = env.engine else {
            message = "引擎还没启动完成"
            return
        }
        busy = true
        let input = text
        Task {
            let result = await engine.addManual(text: input)
            busy = false
            if let failure = result.failure {
                message = "添加失败：\(failure)"
            } else if result.parsed == 0 {
                message = "没有识别到 http(s) 链接"
            } else if result.added == 0 {
                message = "识别到 \(result.parsed) 条链接，都已经在队列或历史里了"
            } else {
                // 不再添加成功就关窗：留下明细与「撤销本次添加」，误粘贴可以一次撤回。
                addedIDs = result.addedIDs
                finished = true
                message = "已新增 \(result.added) 条"
                    + (result.duplicates > 0 ? "，另有 \(result.duplicates) 条重复已跳过" : "")
                    + "。"
            }
        }
    }

    private func undo() {
        guard let engine = env.engine, !addedIDs.isEmpty else { return }
        busy = true
        let ids = addedIDs
        Task {
            let removed = await engine.undoManual(taskIDs: ids)
            busy = false
            addedIDs = []
            finished = false
            message = removed > 0
                ? "已撤销 \(removed) 条；已经开始下载的不撤销"
                : "没有可撤销的任务（可能已经开始下载了）"
        }
    }
}