import AppKit
import LiuYingCore
import SwiftUI

/// 队列：紧凑列表 + 行内展开日志与操作。
struct QueueScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared
    @State private var expandedID: Int64?
    @State private var stateFilter: TaskState?

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
    }

    private func chip(_ title: String, selected: Bool, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                )
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func row(_ task: DownloadTask) -> some View {
        let expanded = expandedID == task.id
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
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
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                detail(task).transition(.opacity)
            }
        }
        .padding(.vertical, 3)
    }

    private func detail(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.rawURL)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            if let error = task.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
            }

            ForEach(task.outputs) { output in
                HStack(spacing: 6) {
                    Image(systemName: "film").font(.caption2).foregroundStyle(.tertiary)
                    Text(output.path)
                        .font(.system(size: 11, design: .monospaced))
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
                if task.state == .failed || task.state == .done {
                    Button("重新下载") {
                        Task {
                            await env.engine?.retry(taskID: task.id)
                        }
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
                Button("移除", role: .destructive) {
                    Task {
                        await env.engine?.remove(taskID: task.id)
                        expandedID = nil
                    }
                }
                .disabled(task.state == .downloading)
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private var logView: some View {
        ScrollView {
            Text(snapshot.currentLog.suffix(120).joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 160)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
    }

    private func metaLine(_ task: DownloadTask) -> String {
        var parts = [task.state.displayName]
        if task.attempts > 1 { parts.append("第 \(task.attempts) 次") }
        if let owner = task.ownerName { parts.append(owner) }
        parts.append(Self.formatter.string(from: task.updatedAt))
        return parts.joined(separator: " · ")
    }

    private func color(for state: TaskState) -> Color {
        switch state {
        case .pending: .secondary
        case .downloading: .accentColor
        case .done: .green
        case .failed: .red
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

/// 手动添加链接。
struct AddLinkSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加链接").font(.headline)
            Text("粘贴分享文案、BV 号链接或 b23.tv 短链，一行一条。也可以直接把链接拖进来。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 140)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .dropDestination(for: String.self) { items, _ in
                    text += (text.isEmpty ? "" : "\n") + items.joined(separator: "\n")
                    return true
                }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(busy ? "添加中…" : "添加到队列") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func add() {
        guard let engine = env.engine else {
            message = "引擎还没启动完成"
            return
        }
        busy = true
        let input = text
        Task {
            let added = await engine.addManual(text: input)
            busy = false
            if added > 0 {
                dismiss()
            } else if URLExtractor.extract(from: input).isEmpty {
                message = "没有识别到 B 站链接"
            } else {
                message = "这些链接都已经在队列或历史里了"
            }
        }
    }
}