import LiuYingCore
import SwiftUI

/// 主窗口：单页 + 分段切换（视频库 / 队列 / 订阅）。
struct MainWindow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarding_done")

    var body: some View {
        VStack(spacing: 0) {
            if let error = env.startupError {
                StartupErrorBanner(message: error)
            }

            PermissionBanner()

            toolbar

            Divider()

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
        .background(.background)
        .sheet(isPresented: Binding(
            get: { state.showAddLink },
            set: { state.showAddLink = $0 }
        )) {
            AddLinkSheet()
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            // 不管是点「开始使用」还是 Esc 关掉，都算完成引导并启动引擎 ——
            // 否则引导页一关，轮询就永远不启动了。
            UserDefaults.standard.set(true, forKey: "onboarding_done")
            Task {
                await env.engine?.start()
                await env.engine?.tickNow()
            }
        }) {
            OnboardingView()
                .environment(env)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(
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

            Spacer(minLength: 8)

            TextField("搜索标题或 UP 主", text: Binding(
                get: { state.searchText },
                set: { state.searchText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 240)

            Button {
                state.showAddLink = true
            } label: {
                Image(systemName: "plus")
            }
            .help("添加链接")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct StartupErrorBanner: View {
    var message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("启动失败：\(message)")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
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
                    Image(systemName: "lock.shield.fill").foregroundStyle(.red)
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
                .background(.red.opacity(0.10))
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