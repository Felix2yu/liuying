import AppKit
import LiuYingCore
import SwiftUI

/// 队列：卡片列表 + 行内展开日志与操作。
struct QueueScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedID: Int64?
    @State private var stateFilter: TaskState?
    @State private var pendingRemoval: Int64?

    private var snapshot: EngineSnapshot { env.model.snapshot }

    /// 顶部计数必须用全库统计。`snapshot.recent` 只是当前分页窗口，
    /// 拿它计数会把「总数」错误地显示成分页大小（默认 30）。
    private var totalTaskCount: Int {
        max(snapshot.stats.values.reduce(0, +), snapshot.recent.count)
    }

    private func totalCount(for state: TaskState) -> Int {
        let loaded = snapshot.recent.lazy.filter { $0.state == state }.count
        return max(snapshot.stats[state] ?? 0, loaded)
    }

    private var trimmedKeyword: String {
        state.searchText.trimmingCharacters(in: .whitespaces)
    }

    /// 当前筛选下，全库还有多少条没装进已加载窗口。
    /// 搜索词无法在本地对全库计数，所以有关键词时这个数只代表状态维度。
    private var unloadedCount: Int {
        let total = stateFilter.map { totalCount(for: $0) } ?? totalTaskCount
        let loaded = snapshot.recent.lazy.filter { task in
            stateFilter == nil || task.state == stateFilter
        }.count
        return max(0, total - loaded)
    }

    private var filtered: [DownloadTask] {
        let keyword = trimmedKeyword.lowercased()
        return snapshot.recent.filter { task in
            if let stateFilter, task.state != stateFilter { return false }
            guard !keyword.isEmpty else { return true }
            return task.displayTitle.lowercased().contains(keyword)
                || (task.ownerName ?? "").lowercased().contains(keyword)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "下载队列", subtitle: snapshot.statusLine) {
                Button {
                    togglePause()
                } label: {
                    Label(
                        snapshot.isPaused ? "继续" : "暂停",
                        systemImage: snapshot.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .disabled(env.engine == nil)

                Button {
                    Task { await env.engine?.tickNow() }
                } label: {
                    Label("立即检查", systemImage: "arrow.clockwise")
                }
                .disabled(env.engine == nil)
            }

            filterBar
            Divider()
            mainList
        }
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

    private func togglePause() {
        Task {
            if snapshot.isPaused {
                await env.engine?.resume()
            } else {
                await env.engine?.pause()
            }
        }
    }

    // MARK: - 列表

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip("全部", count: totalTaskCount, selected: stateFilter == nil) {
                    stateFilter = nil
                }
                ForEach(TaskState.allCases, id: \.self) { state in
                    FilterChip(
                        state.displayName,
                        count: totalCount(for: state),
                        selected: stateFilter == state
                    ) {
                        stateFilter = state
                    }
                }
            }
            .padding(.horizontal, AppMetric.pagePadding)
            .padding(.bottom, 12)
        }
    }

    private var mainList: some View {
        ScrollView {
            LazyVStack(spacing: AppMetric.rowSpacing) {
                if filtered.isEmpty {
                    emptyContent
                } else {
                    ForEach(filtered) { task in
                        row(task)
                            .id("task:\(task.id)")
                    }
                }

                if snapshot.recentTruncated {
                    historyFooter
                }
            }
            .padding(.horizontal, AppMetric.pagePadding)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        EmptyStateView(
            icon: stateFilter == nil && trimmedKeyword.isEmpty
                ? "tray"
                : "line.3.horizontal.decrease.circle",
            title: stateFilter == nil && trimmedKeyword.isEmpty ? "队列是空的" : "没有匹配的任务",
            message: emptyMessage
        ) {
            if stateFilter == nil && trimmedKeyword.isEmpty {
                Button("添加链接…", systemImage: "plus") {
                    state.showAddLink = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyMessage: String {
        if stateFilter == nil && trimmedKeyword.isEmpty {
            return "从 iPhone 分享链接，或在菜单栏里添加链接。"
        }
        var parts = ["已加载的最近 \(snapshot.recent.count) 条里没有匹配的任务。"]
        if unloadedCount > 0 && snapshot.recentTruncated {
            parts.append("更早的记录里还有 \(unloadedCount) 条，点下方「加载更多历史」继续找。")
        }
        return parts.joined(separator: "\n")
    }

    private var historyFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    Task { await env.engine?.showMoreHistory() }
                } label: {
                    Label("加载更多历史", systemImage: "clock.arrow.circlepath")
                }
                .controlSize(.regular)
                Text("已加载 \(snapshot.recent.count) / 共 \(totalTaskCount) 条")
                    .font(AppFont.hint)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if stateFilter != nil && unloadedCount > 0 {
                InfoNote(text: "当前筛选还有 \(unloadedCount) 条更早的记录未加载。")
            } else if !trimmedKeyword.isEmpty {
                InfoNote(text: "更早的记录尚未加载，可能还有匹配项。")
            }
        }
        .padding(.top, 6)
    }

    private func row(_ task: DownloadTask) -> some View {
        let expanded = expandedID == task.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    expandedID = expanded ? nil : task.id
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(task.state.tint.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: task.state.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(task.state.tint)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.displayTitle)
                            .font(AppFont.rowTitle)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Text(metaLine(task))
                            .font(AppFont.rowMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    if task.state == .downloading {
                        if let progress = liveProgress(for: task) {
                            HStack(spacing: 6) {
                                ProgressView(value: min(max(progress.percent, 0), 100), total: 100)
                                    .progressViewStyle(.linear)
                                    .frame(width: 64)
                                Text(String(format: "%.0f%%", progress.percent))
                                    .font(AppFont.rowMeta)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("正在下载 \(progress.displayText)"))
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("正在下载"))
                        }
                    }
                    StatusPill(text: task.state.displayName, color: task.state.tint)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(expanded ? "已展开" : "已折叠"))

            if expanded {
                Divider()
                    .padding(.vertical, 10)
                detail(task)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .rowCard()
    }

    /// 只有「当前正在下载的那个任务」才有实时进度；其它行拿不到，返回 nil 退回转圈。
    private func liveProgress(for task: DownloadTask) -> DownloadProgress? {
        guard snapshot.currentTaskID == task.id,
              let progress = snapshot.currentProgress,
              progress.percent > 0 else { return nil }
        return progress
    }

    private func detail(_ task: DownloadTask) -> some View {        VStack(alignment: .leading, spacing: 10) {
            Text(task.rawURL)
                .font(AppFont.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            if task.state == .sent {
                InfoNote(text: "进度请在 Downie 里查看；文件下好后回到这里点「已下载，标记完成」。")
            }

            if let error = task.error, !error.isEmpty {
                Text(error)
                    .font(AppFont.monoStrong)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .adaptiveTint(.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            ForEach(task.outputs) { output in
                HStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(output.path)
                        .font(AppFont.mono)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("显示") {
                        NSWorkspace.shared.selectFile(output.path, inFileViewerRootedAtPath: "")
                    }
                    .controlSize(.regular)
                }
            }

            if snapshot.currentTaskID == task.id {
                logView
            }

            HStack(spacing: 8) {
                if task.state == .sent {
                    Button {
                        Task { await env.engine?.confirm(taskID: task.id) }
                    } label: {
                        Label("已下载，标记完成", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if task.state == .failed || task.state == .done
                    || task.state == .cancelled || task.state == .sent {
                    Button {
                        Task { await env.engine?.retry(taskID: task.id) }
                    } label: {
                        Label("重新下载", systemImage: "arrow.clockwise")
                    }
                }
                if task.state == .downloading {
                    Button {
                        Task { await env.engine?.cancelCurrentDownload() }
                    } label: {
                        Label("取消当前", systemImage: "stop.fill")
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.rawURL, forType: .string)
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    pendingRemoval = task.id
                } label: {
                    Label("移除…", systemImage: "trash")
                }
                .disabled(task.state == .downloading)
            }
            .controlSize(.regular)
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("实时日志")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(snapshot.currentLog.suffix(120).joined(separator: "\n"))
                    .font(AppFont.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 200)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    private func metaLine(_ task: DownloadTask) -> String {
        var parts: [String] = []
        if let owner = task.ownerName { parts.append(owner) }
        if task.attempts > 1 { parts.append("第 \(task.attempts) 次") }
        if let next = task.nextRetryAt, next > Date() {
            parts.append("\(next.formatted(date: .omitted, time: .shortened)) 后重试")
        }
        parts.append(task.source.displayName)
        parts.append(task.updatedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
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
        VStack(alignment: .leading, spacing: 14) {
            Text("添加链接")
                .font(.title2.weight(.semibold))
            Text("粘贴分享文案、BV 号链接或 b23.tv 短链，一行一条。也可以直接把链接拖进来。")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 14, design: .monospaced))
                .frame(minHeight: 180)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                .dropDestination(for: String.self) { items, _ in
                    text += (text.isEmpty ? "" : "\n") + items.joined(separator: "\n")
                    return true
                }

            if let message {
                Text(message)
                    .font(AppFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if finished {
                    Button("撤销本次添加") { undo() }
                        .disabled(busy)
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    Button("取消") { dismiss() }
                    Button(busy ? "添加中…" : "添加到队列") { add() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(minWidth: 520, idealWidth: 620)
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
