import AppKit
import LiuYingCore
import SwiftUI

/// 主窗口：单页 + 分段切换（视频库 / 队列 / 订阅）。
struct MainWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings
    @State private var state = MainWindowState.shared
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarding_done")
    /// 区分「开始使用」与「稍后设置」：只有前者才算走完引导。
    @State private var onboardingFinished = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = env.startupError {
                StartupErrorBanner(message: error)
            }

            PermissionBanner()

            Group {
                switch state.selectedTab {
                case .library: LibraryScreen()
                case .queue: QueueScreen()
                case .subscriptions: SubscriptionScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        // 窗口标题随当前区域变化，不用 App 名（HIG Toolbars > Titles）。
        .navigationTitle(state.selectedTab.displayName)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("当前视图", selection: Binding(
                    get: { state.selectedTab },
                    set: { state.selectedTab = $0 }
                )) {
                    ForEach(MainWindowState.Tab.allCases) { tab in
                        Text(tab.displayName).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityValue(Text(state.selectedTab.displayName))
            }

            // 一个控件一个 ToolbarItem：放在同一个 HStack 里会被系统合并成单个
            // 工具栏项，AX 描述会串到相邻按钮上（隔离实例 AX 树已复现）。
            ToolbarItem(placement: .primaryAction) {
                searchField
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置")
                .accessibilityLabel(Text("设置"))
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.showAddLink = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加链接")
                .accessibilityLabel(Text("添加链接"))
            }
        }
        .sheet(isPresented: Binding(
            get: { state.showAddLink },
            set: { state.showAddLink = $0 }
        )) {
            AddLinkSheet()
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            // 「稍后设置」不写这个标记，下次启动还会再提示一次。
            if onboardingFinished {
                UserDefaults.standard.set(true, forKey: "onboarding_done")
            }
            // 引擎在 bootstrap 里已经启动，这里只是保证关掉引导后立刻补跑一轮。
            Task {
                await env.engine?.start()
                await env.engine?.tickNow()
            }
        }) {
            OnboardingView(didFinish: $onboardingFinished)
                .environment(env)
        }
    }

    /// 保留全站统一的 FieldContainer 扁平框外观，只把它作为系统工具栏项承载：
    /// 不再自绘整条工具栏，也不再覆盖系统提供的窗口材质。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("搜索标题或 UP 主", text: Binding(
                get: { state.searchText },
                set: { state.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .accessibilityLabel(Text("搜索标题或 UP 主"))
            if !state.searchText.isEmpty {
                Button {
                    state.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel(Text("清除搜索"))
            }
        }
        .modifier(FieldContainer())
        .frame(maxWidth: 240)
    }
}

struct StartupErrorBanner: View {
    var message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("启动失败：\(message)")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .adaptiveTint(.orange, in: Rectangle())
    }
}

/// 只在 iCloud 访问被拦时出现。
struct PermissionBanner: View {
    @Environment(AppEnvironment.self) private var env
    @State private var status: PermissionProbe.Status = .ok

    var body: some View {
        Group {
            if status.isBlocking {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("无法访问 iCloud 里的链接文件").font(.callout.weight(.medium))
                        Text(status.displayText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("打开完全磁盘访问权限…") {
                        PermissionProbe.openFullDiskAccessSettings()
                    }
                    .controlSize(.small)
                    Button("重新检测") { Task { await probe() } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .adaptiveTint(.red, in: Rectangle())
            }
        }
        .task { await probe() }
        .onChange(of: env.model.snapshot.linkStatusHealthy) { _, _ in
            Task { await probe() }
        }
    }

    private func probe() async {
        let path = env.configStore.config.watchFile
        let target = path.trimmingCharacters(in: .whitespaces).isEmpty
            ? ICloudDiscovery.root
            : AppIdentity.expand(path)
        status = await PermissionProbe.probeGuarded(path: target)
    }
}
