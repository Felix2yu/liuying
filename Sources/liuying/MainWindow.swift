import AppKit
import LiuYingCore
import SwiftUI

/// 主窗口：左侧分类栏 + 右侧内容区（视频库 / 队列 / 订阅）。
///
/// 参考 Downie 这类下载管理器：分类固定在侧边栏，内容区只留大标题、筛选与列表；
/// 状态、暂停等低频操作收在侧边栏底部，不再和内容抢工具栏空间。
struct MainWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings
    @State private var state = MainWindowState.shared
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarding_done")
    /// 区分「开始使用」与「稍后设置」：只有前者才算走完引导。
    @State private var onboardingFinished = false

    private var snapshot: EngineSnapshot { env.model.snapshot }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 980, minHeight: 640)
        // 给 NSWindow 打标：⌘V 监听只认这个窗口，不碰设置窗口与其它面板。
        .background(alignment: .topLeading) {
            MainWindowTag()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            MainWindowSizing()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        // ⌘V / 导入共用的非模态反馈，不抢焦点、自动消失。
        .overlay(alignment: .bottom) { feedbackBanner }
        .sheet(isPresented: Binding(
            get: { state.showAddLink },
            set: { state.showAddLink = $0 }
        )) {
            AddLinkSheet()
        }
        .sheet(isPresented: Binding(
            get: { state.showImportDownie },
            set: { state.showImportDownie = $0 }
        )) {
            ImportDownieSheet()
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

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: tabSelection) {
                Section("媒体库") {
                    ForEach(MainWindowState.Tab.allCases) { tab in
                        sidebarRow(tab)
                            .tag(tab)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            engineFooter
        }
    }

    private var tabSelection: Binding<MainWindowState.Tab?> {
        Binding(
            get: { state.selectedTab },
            set: { if let tab = $0 { state.selectedTab = tab } }
        )
    }

    private func sidebarRow(_ tab: MainWindowState.Tab) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 15))
                .frame(width: 22, alignment: .center)
            Text(tab.displayName)
                .font(AppFont.sidebarItem)
            Spacer(minLength: 6)
            if tab == .queue {
                let active = snapshot.pendingCount + snapshot.downloadingCount
                if active > 0 {
                    Text("\(active)")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel(Text("待处理 \(active) 个任务"))
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// 引擎状态与暂停入口放在侧边栏底部：常驻可见，又不会挤占内容区。
    private var engineFooter: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(snapshot.statusLine)
                    .font(AppFont.hint)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Button {
                    togglePause()
                } label: {
                    Label(
                        snapshot.isPaused ? "继续轮询" : "暂停轮询",
                        systemImage: snapshot.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(env.engine == nil)

                Button {
                    Task { await env.engine?.tickNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("立即检查链接文件")
                .accessibilityLabel(Text("立即检查"))
                .disabled(env.engine == nil)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        if snapshot.isPaused { return .orange }
        if snapshot.downloadingCount > 0 { return .accentColor }
        if snapshot.pendingCount > 0 { return .secondary }
        return .green
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

    // MARK: - 内容区

    private var detail: some View {
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
            // 内容区自己滚动，任何溢出（横向 chip、长行）都不许画到侧边栏材质下面。
            .clipped()
        }
        .navigationTitle(state.selectedTab.displayName)
        .toolbar {
            // 一个控件一个 ToolbarItem：放在同一个 HStack 里会被系统合并成单个
            // 工具栏项，AX 描述会串到相邻按钮上（隔离实例 AX 树已复现）。
            ToolbarItem(placement: .primaryAction) {
                searchField
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.showAddLink = true
                } label: {
                    Label("添加链接", systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
                .help("添加链接（⌘N）")
                .accessibilityLabel(Text("添加链接"))
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
        }
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let message = env.feedback.message {
            HStack(spacing: 10) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(AppFont.body)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if !env.feedback.undoIDs.isEmpty {
                    Button("撤销") { undoPaste() }
                        .controlSize(.regular)
                }
                Button {
                    env.feedback.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .controlSize(.regular)
                .accessibilityLabel(Text("关闭提示"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
            .padding(14)
            .frame(maxWidth: 560)
        }
    }

    private func undoPaste() {
        let ids = env.feedback.undoIDs
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            let removed = await env.engine?.undoManual(taskIDs: ids) ?? 0
            env.feedback.show(
                removed > 0
                    ? "已撤销 \(removed) 条；已经开始下载的不撤销"
                    : "没有可撤销的任务（可能已开始下载）"
            )
        }
    }

    /// 保留全站统一的 FieldContainer 扁平框外观，只把它作为系统工具栏项承载：
    /// 不再自绘整条工具栏，也不再覆盖系统提供的窗口材质。
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("搜索标题或 UP 主", text: Binding(
                get: { state.searchText },
                set: { state.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(AppFont.body)
            .accessibilityLabel(Text("搜索标题或 UP 主"))
            if !state.searchText.isEmpty {
                Button {
                    state.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel(Text("清除搜索"))
            }
        }
        .modifier(FieldContainer())
        .frame(maxWidth: 280)
    }
}

extension MainWindowState.Tab {
    var symbolName: String {
        switch self {
        case .library: "film.stack"
        case .queue: "arrow.down.circle"
        case .subscriptions: "person.2"
        }
    }
}

/// 旧版本记住的窗口 frame 可能小于新布局的下限（新侧边栏需要 980pt 宽）。
/// Window scene 只在首次创建时应用 defaultSize，恢复旧 frame 时不会重新按 minSize 收敛；
/// 这里在窗口上屏后补一次约束，必要时放大到下限。
struct MainWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MainWindowSizingView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class MainWindowSizingView: NSView {
    static let minSize = NSSize(width: 980, height: 640)
    private var applied = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.contentMinSize = Self.minSize
        window.minSize = Self.minSize
        guard !applied else { return }
        applied = true
        // 窗口恢复旧 frame 后再收敛；延迟一帧，避免被 SwiftUI 的首轮布局覆盖。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            Self.enforce(window)
        }
    }

    private static func enforce(_ window: NSWindow) {
        var content = window.contentLayoutRect.size
        guard content.width < minSize.width || content.height < minSize.height else { return }
        content.width = max(content.width, minSize.width)
        content.height = max(content.height, minSize.height)
        window.setContentSize(content)
    }
}

struct StartupErrorBanner: View {
    var message: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("启动失败：\(message)")
                .font(AppFont.body)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("无法访问 iCloud 里的链接文件")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(status.displayText)
                            .font(AppFont.hint)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("打开完全磁盘访问权限…") {
                        PermissionProbe.openFullDiskAccessSettings()
                    }
                    .controlSize(.regular)
                    Button("重新检测") { Task { await probe() } }
                        .controlSize(.regular)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
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
