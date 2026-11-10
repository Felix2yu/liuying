import LiuYingCore
import SwiftUI

/// 订阅：填 UP 主 UID，自动抓新投稿。
struct SubscriptionScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var subscriptions: [Subscription] = []
    @State private var expandedID: Int64?
    @State private var newMid = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var busy = false
    @State private var pendingDelete: Int64?

    private var filtered: [Subscription] {
        let keyword = state.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return subscriptions }
        return subscriptions.filter {
            $0.displayName.lowercased().contains(keyword) || String($0.mid).contains(keyword)
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("UP 主 UID（数字，例如 486906719）", text: $newMid)
                        .modifier(FieldContainer())
                        .frame(maxWidth: 280)
                    Button(busy ? "添加中…" : "添加订阅") { add() }
                        .disabled(busy || validMID == nil)
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                if !newMid.trimmingCharacters(in: .whitespaces).isEmpty, validMID == nil {
                    Text("请填纯数字的正整数 UID；超长、含符号或负数都不会添加")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("首次同步只记录最新水位，不会把历史投稿全部下载 —— 需要时用「导入最近 N 条」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if filtered.isEmpty {
                    Text(subscriptions.isEmpty
                         ? "还没有订阅。填一个 UP 主 UID 开始追更。"
                         : "没有匹配的订阅。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(filtered) { subscription in
                        row(subscription)
                            .id("sub:\(subscription.id)")
                    }
                }
            }
        }
        .listStyle(.inset)
        .task { await reload() }
        .onChange(of: state.selectedTab) { _, tab in
            if tab == .subscriptions { Task { await reload() } }
        }
        .confirmationDialog(
            "删除这个订阅？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除订阅", role: .destructive) {
                guard let id = pendingDelete else { return }
                pendingDelete = nil
                expandedID = nil
                Task {
                    let error = await env.subscriptions?.remove(id: id)
                    message = error ?? "已删除订阅，已入队的任务不受影响"
                    messageIsError = error != nil
                    await reload()
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只删除订阅与水位，已经入队的下载任务会保留。")
        }
    }

    private var validMID: Int64? {
        guard let mid = Int64(newMid.trimmingCharacters(in: .whitespaces)), mid > 0 else { return nil }
        return mid
    }

    private func row(_ subscription: Subscription) -> some View {
        let expanded = expandedID == subscription.id
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    expandedID = expanded ? nil : subscription.id
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(subscription.enabled ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .offset(y: -1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.displayName).font(.callout)
                        Text(metaLine(subscription))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Toggle("启用 \(subscription.displayName)", isOn: Binding(
                        get: { subscription.enabled },
                        set: { enabled in
                            Task {
                                let error = await env.subscriptions?.setEnabled(
                                    id: subscription.id, enabled: enabled
                                )
                                message = error
                                messageIsError = error != nil
                                await reload()
                            }
                        }
                    ))
                    .labelsHidden()
                    .accessibilityLabel(Text("启用 \(subscription.displayName)"))
                    .accessibilityValue(Text(subscription.enabled ? "已启用" : "已停用"))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(busy)
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
                VStack(alignment: .leading, spacing: 6) {
                    if let reason = subscription.disabledReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.red)
                    }
                    HStack(spacing: 6) {
                        Button(busy ? "处理中…" : "立即刷新") { refresh(id: subscription.id) }
                            .disabled(busy)
                        Button("导入最近 5 条") { importRecent(id: subscription.id) }
                            .disabled(busy || !subscription.initialSyncDone)
                        Button("打开主页") {
                            NSWorkspace.shared.open(
                                URL(string: "https://space.bilibili.com/\(subscription.mid)")!
                            )
                        }
                        Spacer()
                        Button("删除订阅…", role: .destructive) { pendingDelete = subscription.id }
                            .disabled(busy)
                    }
                    .controlSize(.small)
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(.vertical, 3)
    }

    private func metaLine(_ subscription: Subscription) -> String {
        var parts = ["UID \(subscription.mid)"]
        if let name = subscription.name { parts.append(name) }
        parts.append("已捕获 \(subscription.capturedCount)")
        if let polled = subscription.lastPolled {
            parts.append("上次 \(polled.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func add() {
        guard let mid = validMID, !busy else { return }
        busy = true
        message = nil
        Task {
            if let error = await env.subscriptions?.add(mid: mid) {
                message = error
                messageIsError = true
            } else {
                newMid = ""
                message = "已添加 UID \(mid)，首次同步完成"
                messageIsError = false
            }
            busy = false
            await reload()
        }
    }

    private func refresh(id: Int64) {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            let outcome = await env.subscriptions?.pollNow(subscriptionID: id)
            message = Self.describe(outcome, action: "刷新")
            messageIsError = message?.contains("失败") == true
            busy = false
            await reload()
        }
    }

    private func importRecent(id: Int64) {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            let outcome = await env.subscriptions?.importRecent(subscriptionID: id, count: 5)
            message = Self.describe(outcome, action: "导入")
            messageIsError = message?.contains("失败") == true
            busy = false
            await reload()
        }
    }

    private static func describe(_ outcome: SubscriptionPoller.PollOutcome?, action: String) -> String {
        guard let outcome else { return "\(action)失败：订阅服务还没启动完成" }
        if let error = outcome.error { return "\(action)失败：\(error)" }
        if outcome.initialSync { return "首次同步完成，已记录最新水位，没有入队历史投稿" }
        return outcome.added > 0
            ? "\(action)完成，新增 \(outcome.added) 条投稿"
            : "\(action)完成，没有新投稿"
    }

    private func reload() async {
        do {
            subscriptions = try await env.subscriptions?.all() ?? []
        } catch {
            message = "读取订阅列表失败：\(error.localizedDescription)"
            messageIsError = true
        }
    }
}
