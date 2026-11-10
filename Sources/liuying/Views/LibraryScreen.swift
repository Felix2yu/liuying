import AppKit
import LiuYingCore
import SwiftUI

/// 视频库：紧凑列表，选中行就地展开详情。
struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var videos: [LibraryVideo] = []
    @State private var expandedID: String?
    @State private var ownerFilter: String?
    @State private var focusID: String?
    @State private var scanner = LibraryScanner()
    @State private var isLoading = false
    @State private var pendingDelete: LibraryVideo?
    @State private var scanError: String?
    @State private var actionError: String?

    private var downloadDir: String { env.configStore.resolvedDownloadDir }

    private var owners: [String] {
        Array(Set(videos.compactMap(\.owner))).sorted()
    }

    private var filtered: [LibraryVideo] {
        let keyword = state.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return videos.filter { video in
            if let ownerFilter, video.owner != ownerFilter { return false }
            guard !keyword.isEmpty else { return true }
            return video.title.lowercased().contains(keyword)
                || (video.owner ?? "").lowercased().contains(keyword)
        }
    }

    private var totalBytes: Int64 { videos.reduce(0) { $0 + $1.bytes } }

    /// 列表单独抽出：body 上挂了多个 onChange + alert，整个表达式会让 Swift 类型检查超时。
    private var mainList: some View {
        ScrollViewReader { proxy in
            List {
                if let actionError {
                    errorBanner(actionError)
                }
                Section {
                    filterChips
                }
                Section {
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        ForEach(filtered) { video in
                            row(video)
                                .id("video:\(video.path)")
                        }
                    }
                } header: {
                    Text("\(filtered.count) 个视频 · \(Self.sizeText(totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .onChange(of: focusID) { _, newValue in
                guard let newValue else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo("video:\(newValue)", anchor: .center)
                }
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.caption)
                Spacer()
                Button("关闭") { actionError = nil }.controlSize(.small)
            }
        }
    }

    var body: some View {
        mainList
        .task { await reload() }
        .onChange(of: state.selectedTab) { _, tab in
            if tab == .library { Task { await reload() } }
        }
        // 引擎确认下载完成后主动失效库缓存，不用手动切 tab 才能看到新视频。
        .onChange(of: env.model.snapshot.libraryRevision) { _, _ in
            Task {
                await scanner.invalidate()
                await reload()
            }
        }
        .onChange(of: state.focusID) { _, newValue in
            guard let hint = newValue else { return }
            // 深链进入时先清筛选，否则目标行可能被 owner/关键词挡住。
            ownerFilter = nil
            state.searchText = ""
            guard let match = resolveFocus(hint) else {
                actionError = "视频库里没找到这次下载的文件（可能尚未落盘，或下载目录不同）：\(hint)"
                state.focusID = nil
                return
            }
            expandedID = match.path
            focusID = match.path
            state.focusID = nil
        }
        .alert("删除视频文件？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { video in
            Button("删除", role: .destructive) {
                do {
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: video.path), resultingItemURL: nil
                    )
                    pendingDelete = nil
                    Task {
                        await scanner.invalidate()
                        await reload()
                    }
                } catch {
                    // 旧实现把失败吞掉，用户会以为文件已经删了。
                    pendingDelete = nil
                    actionError = "移到废纸篓失败：\(error.localizedDescription)"
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { video in
            Text("\(video.displayTitle)\n会移到废纸篓。")
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "全部", selected: ownerFilter == nil) { ownerFilter = nil }
                ForEach(owners, id: \.self) { owner in
                    chip(title: owner, selected: ownerFilter == owner) { ownerFilter = owner }
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(minHeight: 20)
                .chipBackground(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if let scanError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(scanError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("打开完全磁盘访问权限…") {
                        PermissionProbe.openFullDiskAccessSettings()
                    }
                    Button("重新扫描") {
                        Task {
                            await scanner.invalidate()
                            await reload()
                        }
                    }
                }
                .controlSize(.small)
            } else {
                Image(systemName: "film.stack")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(isLoading ? "正在扫描…" : "这里还没有视频")
                    .foregroundStyle(.secondary)
            }
            Text(downloadDir)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func row(_ video: LibraryVideo) -> some View {
        let expanded = expandedID == video.path
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    expandedID = expanded ? nil : video.path
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(video.displayTitle)
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(metaLine(video))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(video.container.uppercased())
                        .font(.caption2.weight(.semibold))
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
                detail(video)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(.vertical, 3)
    }

    private func detail(_ video: LibraryVideo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(path: video.path)
                .frame(width: 160, height: 90)

            VStack(alignment: .leading, spacing: 6) {
                Text(video.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Button("播放") { NSWorkspace.shared.open(URL(fileURLWithPath: video.path)) }
                    if let iina = Self.iinaURL {
                        Button("用 IINA 打开") {
                            NSWorkspace.shared.open(
                                [URL(fileURLWithPath: video.path)],
                                withApplicationAt: iina,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                        }
                    }
                    Button("访达中显示") {
                        NSWorkspace.shared.selectFile(video.path, inFileViewerRootedAtPath: "")
                    }
                    Button("复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(video.path, forType: .string)
                    }
                    if let bvid = bvid(for: video) {
                        Button("打开 B 站") {
                            NSWorkspace.shared.open(URL(string: "https://www.bilibili.com/video/\(bvid)")!)
                        }
                    }
                    Spacer()
                    Button("删除…", role: .destructive) { pendingDelete = video }
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    private func metaLine(_ video: LibraryVideo) -> String {
        var parts: [String] = []
        if let owner = video.owner { parts.append(owner) }
        parts.append(Self.sizeText(video.bytes))
        parts.append(video.modified.formatted(date: .numeric, time: .omitted))
        return parts.joined(separator: " · ")
    }

    /// 深链定位：优先精确路径，其次按任务产出/去重键找到任务标题再匹配，
    /// 最后再用 BV 号在文件名里做包含匹配。菜单传的 hint 可能是产出路径或 taskKey。
    private func resolveFocus(_ hint: String) -> LibraryVideo? {
        if let exact = videos.first(where: { $0.path == hint || $0.title == hint }) {
            return exact
        }
        let related = env.model.snapshot.recent.first { task in
            task.taskKey == hint || task.bvid == hint
                || task.outputs.contains { $0.path == hint }
        }
        if let title = related?.title,
           let byTitle = videos.first(where: {
               $0.title.hasPrefix(title) || title.hasPrefix($0.title)
           }) {
            return byTitle
        }
        return videos.first { $0.path.contains(hint) || $0.title.contains(hint) }
    }

    /// 文件系统里没有 BV 号；尽力从任务库按标题反查，查不到就不显示「打开 B 站」。
    private func bvid(for video: LibraryVideo) -> String? {
        env.model.snapshot.recent.first { task in
            guard let title = task.title else { return false }
            return video.title.hasPrefix(title) || title.hasPrefix(video.title)
        }?.bvid
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try FileManager.default.createDirectory(
                atPath: downloadDir, withIntermediateDirectories: true
            )
        } catch {
            videos = []
            scanError = "无法创建下载目录：\(error.localizedDescription)"
            return
        }
        let outcome = await scanner.scanChecked(root: downloadDir)
        videos = outcome.items
        // 超时/没权限不再伪装成「这里还没有视频」。
        scanError = outcome.error?.message
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static var iinaURL: URL? {
        let candidates = ["/Applications/IINA.app", NSHomeDirectory() + "/Applications/IINA.app"]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }
}

/// 懒加载缩略图。生成失败就显示占位，不阻塞列表。
struct ThumbnailView: View {
    let path: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if failed {
                Image(systemName: "film").foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) {
            let thumb = await ThumbnailService.shared.thumbnail(for: path)
            if let thumb, let loaded = NSImage(contentsOfFile: thumb) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// 全局单例，避免每行都新建一个 actor。
enum ThumbnailService {
    static let shared = Thumbnailer()
}