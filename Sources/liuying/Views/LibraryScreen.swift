import AppKit
import LiuYingCore
import SwiftUI

/// 视频库：大缩略图卡片列表，选中行就地展开详情。
struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var videos: [LibraryVideo] = []
    @State private var expandedID: String?
    @State private var ownerFilter: String?
    @State private var showOwnerPicker = false
    @State private var ownerQuery = ""
    @FocusState private var ownerSearchFocused: Bool
    @State private var focusID: String?
    @State private var scanner = LibraryScanner()
    @State private var isLoading = false
    @State private var pendingDelete: LibraryVideo?
    @State private var scanError: String?
    @State private var actionError: String?

    private var downloadDir: String { env.configStore.resolvedDownloadDir }

    private var filtered: [LibraryVideo] {
        let keyword = state.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return videos.filter { video in
            if let ownerFilter, video.owner != ownerFilter { return false }
            guard !keyword.isEmpty else { return true }
            return video.title.lowercased().contains(keyword)
                || (video.owner ?? "").lowercased().contains(keyword)
        }
    }

    private var filteredBytes: Int64 { filtered.reduce(0) { $0 + $1.bytes } }

    private var subtitle: String {
        if isLoading && videos.isEmpty { return "正在扫描下载目录…" }
        return "\(filtered.count) 个视频 · \(Self.sizeText(filteredBytes))"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "视频库", subtitle: subtitle) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("正在扫描"))
                }
                Button {
                    Task { await reload() }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            if !videos.isEmpty {
                filterBar
            }

            Divider()
            mainList
        }
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

    // MARK: - 列表

    /// UP 主一多，横向 chip 会变成一条又长又难定位的滚轴。
    /// 改成「全部 + UP 主菜单」：菜单里带搜索、按视频数排序，人再多也能两步内定位。
    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterChip("全部", count: videos.count, selected: ownerFilter == nil) {
                ownerFilter = nil
            }
            ownerMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppMetric.pagePadding)
        .padding(.bottom, 12)
        .clipped()
    }

    private var ownerMenu: some View {
        Button { showOwnerPicker.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 12))
                Text(ownerFilter ?? "UP 主")
                    .font(.system(size: 13, weight: ownerFilter == nil ? .regular : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule().fill(
                    ownerFilter == nil
                        ? Color(nsColor: .controlBackgroundColor)
                        : Color.accentColor.opacity(0.16)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    ownerFilter == nil
                        ? Color(nsColor: .separatorColor).opacity(0.7)
                        : Color.accentColor.opacity(0.7),
                    lineWidth: 0.75
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("按 UP 主筛选")
        .accessibilityLabel(Text(ownerFilter.map { "UP 主：\($0)" } ?? "选择 UP 主"))
        .popover(isPresented: $showOwnerPicker, arrowEdge: .bottom) {
            ownerPicker
        }
        .onChange(of: showOwnerPicker) { _, showing in
            if !showing { ownerQuery = "" }
        }
    }

    private var ownerPicker: some View {
        let counts = ownerCounts
        let filteredOwners = pickerOwners(counts: counts)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索 UP 主", text: $ownerQuery)
                    .textFieldStyle(.plain)
                    .font(AppFont.body)
                    .focused($ownerSearchFocused)
                if !ownerQuery.isEmpty {
                    Button { ownerQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("清除搜索"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.75)
            )
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ownerRow(nil, label: "全部视频", count: videos.count)
                    ForEach(filteredOwners, id: \.self) { owner in
                        ownerRow(owner, label: owner, count: counts[owner] ?? 0)
                    }
                    if filteredOwners.isEmpty {
                        Text("没有匹配的 UP 主")
                            .font(AppFont.hint)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 300)
        .task {
            // popover 的文本框要等窗口真正上屏才能接收焦点。
            try? await Task.sleep(nanoseconds: 120_000_000)
            ownerSearchFocused = true
        }
    }

    /// 按视频数降序：常用的 UP 主自然浮到前面；搜索则直接按名字过滤。
    private func pickerOwners(counts: [String: Int]) -> [String] {
        let query = ownerQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return counts.keys
            .filter { query.isEmpty || $0.lowercased().contains(query) }
            .sorted { lhs, rhs in
                let left = counts[lhs] ?? 0
                let right = counts[rhs] ?? 0
                if left != right { return left > right }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    private var ownerCounts: [String: Int] {
        Dictionary(grouping: videos.compactMap(\.owner), by: { $0 }).mapValues(\.count)
    }

    private func ownerRow(_ owner: String?, label: String, count: Int) -> some View {
        Button {
            ownerFilter = owner
            showOwnerPicker = false
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 26, height: 26)
                    if let owner {
                        Text(String(owner.prefix(1)))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Image(systemName: "film.stack")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .accessibilityHidden(true)

                Text(label)
                    .font(AppFont.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .font(AppFont.hint)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(ownerFilter == owner ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ownerFilter == owner ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var mainList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppMetric.rowSpacing) {
                    if let actionError {
                        errorCard(actionError)
                    }
                    if filtered.isEmpty {
                        emptyContent
                    } else {
                        ForEach(filtered) { video in
                            row(video)
                                .id("video:\(video.path)")
                        }
                    }
                }
                .padding(.horizontal, AppMetric.pagePadding)
                .padding(.vertical, 14)
            }
            .onChange(of: focusID) { _, newValue in
                guard let newValue else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo("video:\(newValue)", anchor: .center)
                }
            }
        }
    }

    private func errorCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
            Text(text)
                .font(AppFont.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("关闭") { actionError = nil }
                .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .adaptiveTint(.orange, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var emptyContent: some View {
        if let scanError {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "无法读取下载目录",
                message: scanError
            ) {
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
                .controlSize(.regular)
            }
        } else {
            EmptyStateView(
                icon: "film.stack",
                title: isLoading ? "正在扫描…" : "这里还没有视频",
                message: "下载完成的视频会自动出现在这里。"
            ) {
                VStack(spacing: 8) {
                    Text(downloadDir)
                        .font(AppFont.mono)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Button("重新扫描", systemImage: "arrow.clockwise") {
                        Task {
                            await scanner.invalidate()
                            await reload()
                        }
                    }
                }
            }
        }
    }

    private func row(_ video: LibraryVideo) -> some View {
        let expanded = expandedID == video.path
        return VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    expandedID = expanded ? nil : video.path
                }
            } label: {
                HStack(spacing: 14) {
                    ThumbnailView(path: video.path)
                        .frame(width: AppMetric.thumbnail.width, height: AppMetric.thumbnail.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(video.displayTitle)
                            .font(AppFont.rowTitle)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Text(metaLine(video))
                            .font(AppFont.rowMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(video.container.uppercased())
                        .font(AppFont.badge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))

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
                detail(video)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .rowCard()
    }

    private func detail(_ video: LibraryVideo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ThumbnailView(path: video.path)
                    .frame(
                        width: AppMetric.detailThumbnail.width,
                        height: AppMetric.detailThumbnail.height
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("文件位置")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(video.path)
                        .font(AppFont.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                    Text(metaLine(video))
                        .font(AppFont.rowMeta)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: video.path))
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

                if let iina = Self.iinaURL {
                    Button {
                        NSWorkspace.shared.open(
                            [URL(fileURLWithPath: video.path)],
                            withApplicationAt: iina,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    } label: {
                        Label("用 IINA 打开", systemImage: "play.rectangle")
                    }
                }
                Button {
                    NSWorkspace.shared.selectFile(video.path, inFileViewerRootedAtPath: "")
                } label: {
                    Label("访达中显示", systemImage: "folder")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(video.path, forType: .string)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                if let bvid = bvid(for: video) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://www.bilibili.com/video/\(bvid)")!)
                    } label: {
                        Label("打开 B 站", systemImage: "globe")
                    }
                }
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    pendingDelete = video
                } label: {
                    Label("删除…", systemImage: "trash")
                }
            }
            .controlSize(.regular)
        }
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if failed {
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
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
