import LiuYingCore
import SwiftUI

/// 订阅：填 UP 主 UID，自动抓新投稿。
struct SubscriptionScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared

    @State private var subscriptions: [Subscription] = []
    @State private var expandedID: Int64?
    @State private var newMid = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("UP 主 UID（数字，例如 486906719）", text: $newMid)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Button(busy ? "添加中…" : "添加订阅") { add() }
                        .disabled(busy || Int64(newMid.trimmingCharacters(in: .whitespaces)) == nil)
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("首次同步只记录最新水位，不会把历史投稿全部下载 —— 需要时用「导入最近 N 条」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if subscriptions.isEmpty {
                    Text("还没有订阅。填一个 UP 主 UID 开始追更。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(subscriptions) { subscription in
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
    }

    private func row(_ subscription: Subscription) -> some View {
        let expanded = expandedID == subscription.id
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedID = expanded ? nil : subscription.id
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(subscription.enabled ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .offset(y: -1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subscription.displayName).font(.callout)
                        Text(metaLine(subscription))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { subscription.enabled },
                        set: { enabled in
                            Task {
                                await env.subscriptions?.setEnabled(id: subscription.id, enabled: enabled)
                                await reload()
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let reason = subscription.disabledReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.red)
                    }
                    HStack(spacing: 6) {
                        Button("立即刷新") {
                            Task {
                                busy = true
                                await env.subscriptions?.pollNow(subscriptionID: subscription.id)
                                busy = false
                                await reload()
                            }
                        }
                        Button("导入最近 5 条") {
                            Task {
                                busy = true
                                await env.subscriptions?.importRecent(subscriptionID: subscription.id, count: 5)
                                busy = false
                                await reload()
                            }
                        }
                        .disabled(!subscription.initialSyncDone)
                        Button("打开主页") {
                            NSWorkspace.shared.open(
                                URL(string: "https://space.bilibili.com/\(subscription.mid)")!
                            )
                        }
                        Spacer()
                        Button("删除订阅", role: .destructive) {
                            Task {
                                await env.subscriptions?.remove(id: subscription.id)
                                expandedID = nil
                                await reload()
                            }
                        }
                    }
                    .controlSize(.small)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 3)
    }

    private func metaLine(_ subscription: Subscription) -> String {
        var parts = ["UID \(subscription.mid)"]
        if let name = subscription.name { parts.append(name) }
        parts.append("已捕获 \(subscription.capturedCount)")
        if let polled = subscription.lastPolled {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            parts.append("上次 \(formatter.string(from: polled))")
        }
        return parts.joined(separator: " · ")
    }

    private func add() {
        guard let mid = Int64(newMid.trimmingCharacters(in: .whitespaces)) else { return }
        busy = true
        message = nil
        Task {
            if let error = await env.subscriptions?.add(mid: mid) {
                message = error
            } else {
                newMid = ""
            }
            busy = false
            await reload()
        }
    }

    private func reload() async {
        subscriptions = await env.subscriptions?.all() ?? []
    }
}