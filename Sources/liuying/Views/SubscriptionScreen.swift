import AppKit
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

    private var subtitle: String {
        "\(filtered.count) 个 UP 主 · 自动追更新投稿"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "订阅", subtitle: subtitle) {
                InfoTipButton(
                    title: "关于首次同步",
                    text: "首次同步只记录最新水位，不会把历史投稿全部下载。需要补看时，展开订阅用「导入最近 5 条」。"
                )
            }

            addCard
            Divider()
            mainList
        }
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

    // MARK: - 添加

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                TextField("输入 UP 主 UID（纯数字，例如 486906719）", text: $newMid)
                    .textFieldStyle(.plain)
                    .font(AppFont.body)
                    .onSubmit { add() }

                Button(busy ? "添加中…" : "添加订阅") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || validMID == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.75)
            )

            if !newMid.trimmingCharacters(in: .whitespaces).isEmpty, validMID == nil {
                Text("请填纯数字的正整数 UID；超长、含符号或负数都不会添加")
                    .font(AppFont.hint)
                    .foregroundStyle(.red)
            }

            if let message {
                Text(message)
                    .font(AppFont.hint)
                    .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AppMetric.pagePadding)
        .padding(.bottom, 14)
    }

    private var validMID: Int64? {
        guard let mid = Int64(newMid.trimmingCharacters(in: .whitespaces)), mid > 0 else { return nil }
        return mid
    }

    // MARK: - 列表

    private var mainList: some View {
        ScrollView {
            LazyVStack(spacing: AppMetric.rowSpacing) {
                if filtered.isEmpty {
                    EmptyStateView(
                        icon: "person.2",
                        title: subscriptions.isEmpty ? "还没有订阅" : "没有匹配的订阅",
                        message: subscriptions.isEmpty
                            ? "填入 UP 主 UID，新投稿会自动加入下载队列。"
                            : "换个关键词或清空搜索再看看。"
                    )
                } else {
                    ForEach(filtered) { subscription in
                        row(subscription)
                            .id("sub:\(subscription.id)")
                    }
                }
            }
            .padding(.horizontal, AppMetric.pagePadding)
            .padding(.vertical, 14)
        }
    }

    private func row(_ subscription: Subscription) -> some View {
        let expanded = expandedID == subscription.id
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        expandedID = expanded ? nil : subscription.id
                    }
                } label: {
                    HStack(spacing: 12) {
                        avatar(subscription)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(subscription.displayName)
                                    .font(AppFont.rowTitle)
                                    .lineLimit(1)
                                if !subscription.enabled {
                                    StatusPill(text: "已停用", color: .secondary)
                                }
                            }
                            Text(metaLine(subscription))
                                .font(AppFont.rowMeta)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 12)
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
                .controlSize(.regular)
                .disabled(busy)
            }

            if expanded {
                Divider()
                    .padding(.vertical, 10)
                VStack(alignment: .leading, spacing: 10) {
                    if let reason = subscription.disabledReason, !reason.isEmpty {
                        Text(reason)
                            .font(AppFont.hint)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button {
                            refresh(id: subscription.id)
                        } label: {
                            Label(busy ? "处理中…" : "立即刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(busy)

                        Button {
                            importRecent(id: subscription.id)
                        } label: {
                            Label("导入最近 5 条", systemImage: "square.and.arrow.down")
                        }
                        .disabled(busy || !subscription.initialSyncDone)

                        Button {
                            NSWorkspace.shared.open(
                                URL(string: "https://space.bilibili.com/\(subscription.mid)")!
                            )
                        } label: {
                            Label("打开主页", systemImage: "globe")
                        }

                        Spacer(minLength: 8)

                        Button(role: .destructive) {
                            pendingDelete = subscription.id
                        } label: {
                            Label("删除订阅…", systemImage: "trash")
                        }
                        .disabled(busy)
                    }
                    .controlSize(.regular)
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .rowCard()
    }

    private func avatar(_ subscription: Subscription) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 42, height: 42)
            Text(String(subscription.displayName.prefix(1)))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityHidden(true)
    }

    private func metaLine(_ subscription: Subscription) -> String {
        var parts = ["UID \(subscription.mid)"]
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
