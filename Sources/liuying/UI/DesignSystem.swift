import LiuYingCore
import SwiftUI

// MARK: - 字号与尺寸

/// 全站统一的视觉规范。
///
/// 旧界面大量使用 `.caption`（10–11pt）承载正文与说明，在 4K 视网膜屏上灰而小。
/// 这里把可读性下限固定下来：正文 13.5pt、最次要的元信息 12pt、列表标题 15pt、
/// 页面标题 24pt；间距、圆角和缩略图尺寸也一并统一，避免各页面各写一套。
enum AppFont {
    static let pageTitle = Font.system(size: 24, weight: .bold)
    static let pageSubtitle = Font.system(size: 13)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let rowTitle = Font.system(size: 15, weight: .semibold)
    static let rowMeta = Font.system(size: 12.5)
    static let body = Font.system(size: 13.5)
    static let hint = Font.system(size: 12.5)
    static let badge = Font.system(size: 11.5, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoStrong = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let sidebarItem = Font.system(size: 14, weight: .medium)
}

enum AppMetric {
    static let pagePadding: CGFloat = 22
    static let cardCorner: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 8
    static let thumbnail = CGSize(width: 132, height: 74)
    static let detailThumbnail = CGSize(width: 240, height: 135)
}

// MARK: - 页面标题

/// 每个主页面顶部的大标题区：标题、状态摘要、右侧操作。
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    private let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(AppFont.pageTitle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppFont.pageSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                trailing
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, AppMetric.pagePadding)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - 筛选 chip

/// 列表顶部的筛选胶囊。比旧版高 10pt、字号大 2pt，选中态用强调色描边而不是细边框。
struct FilterChip: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    init(_ title: String, count: Int? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.primary.opacity(0.75) : Color.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule().fill(
                    selected
                        ? Color.accentColor.opacity(0.16)
                        : Color(nsColor: .controlBackgroundColor)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    selected
                        ? Color.accentColor.opacity(0.7)
                        : Color(nsColor: .separatorColor).opacity(0.7),
                    lineWidth: 0.75
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 状态胶囊

struct StatusPill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(AppFont.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}

// MARK: - 说明文字

/// 需要保留在页面上的说明：字号不低于 12.5pt，行距放松。
struct InfoNote: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(AppFont.hint)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }
}

/// 把长段解释收进一个「ⓘ」按钮，避免页面上铺满小字。
struct InfoTipButton: View {
    let title: String
    let text: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(Text(title))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(text)
                    .font(AppFont.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
    }
}

// MARK: - 空状态

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String?
    private let actions: Actions

    init(
        icon: String,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            if let message {
                Text(message)
                    .font(AppFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 440)
            }
            actions
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

// MARK: - 行卡片

/// 列表行的统一卡片外观：圆角、描边、悬停高亮。
struct RowCard: ViewModifier {
    var padding: CGFloat = AppMetric.cardPadding
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: AppMetric.cardCorner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppMetric.cardCorner, style: .continuous)
                    .strokeBorder(
                        hovering
                            ? Color.accentColor.opacity(0.35)
                            : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: 0.75
                    )
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowCard(padding: CGFloat = AppMetric.cardPadding) -> some View {
        modifier(RowCard(padding: padding))
    }

    /// 设置页的辅助说明：统一 12.5pt，取代原先 11pt 的 `.caption`。
    func settingsHint(_ color: Color = .secondary) -> some View {
        font(AppFont.hint)
            .foregroundStyle(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 任务状态视觉

extension TaskState {
    var tint: Color {
        switch self {
        case .pending: .secondary
        case .downloading: .accentColor
        case .done: .green
        case .failed: .red
        case .cancelled: .secondary
        case .sent: .orange
        }
    }

    var symbol: String {
        switch self {
        case .pending: "clock"
        case .downloading: "arrow.down"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        case .sent: "paperplane"
        }
    }
}
