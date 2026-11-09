import AppKit
import LiuYingCore
import SwiftUI

/// 视频库：紧凑列表，选中行就地展开详情。
struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var state = MainWindowState.shared

    @State private var videos: [LibraryVideo] = []
    @State private var expandedID: String?
    @State private var ownerFilter: String?
    @State private var focusID: String?
    @State private var scanner = LibraryScanner()
    @State private var isLoading = false
    @State private var pendingDelete: LibraryVideo?

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

    var body: some View {
        ScrollViewReader { proxy in
            List {
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("video:\(newValue)", anchor: .center)
                }
            }
        }
        .task { await reload() }
        .onChange(of: state.selectedTab) { _, tab in
            if tab == .library { Task { await reload() } }
        }
        .onChange(of: state.focusID) { _, newValue in
            guard let newValue else { return }
            // 深链进入时若被筛选挡住，先清筛选，再滚动到目标行。
            if !filtered.contains(where: { $0.path == newValue || $0.title == newValue }) {
                ownerFilter = nil
                state.searchText = ""
            }
            let match = videos.first { $0.path == newValue || $0.title == newValue }
            guard let match else { return }
            expandedID = match.path
            focusID = match.path
            state.focusID = nil
        }
        .alert("删除视频文件？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { video in
            Button("删除", role: .destructive) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: video.path), resultingItemURL: nil)
                pendingDelete = nil
                Task { await reload() }
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
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                )
                .overlay(
                    Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "film.stack").font(.title2).foregroundStyle(.tertiary)
            Text(isLoading ? "正在扫描…" : "这里还没有视频")
                .foregroundStyle(.secondary)
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
                withAnimation(.easeInOut(duration: 0.15)) {
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
                        .font(.system(size: 10, weight: .semibold))
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
                detail(video)
                    .transition(.opacity)
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
                    .font(.system(size: 11, design: .monospaced))
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var parts: [String] = []
        if let owner = video.owner { parts.append(owner) }
        parts.append(Self.sizeText(video.bytes))
        parts.append(formatter.string(from: video.modified))
        return parts.joined(separator: " · ")
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
        try? FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
        videos = await scanner.scan(root: downloadDir)
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
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10))
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