import AppKit
import LiuYingCore
import SwiftUI

/// 设置页复用的输入组件。
///
/// 输入框统一成：标题在上、单行圆角输入框、右侧一个干净的文件夹图标按钮
/// （可选「自动发现」）、底部一条状态/提示。这套扁平框是全站有意统一的视觉语言。

// MARK: - 自适应状态色

/// 状态底色的不透明度随外观与「增加对比度」分档：
/// 固定 alpha 在深色模式会与窗口背景糊在一起，高对比模式下又不够醒目
/// （HIG Color > Best practices）。
enum AdaptiveAppearance {
    static func tintOpacity(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Double {
        switch (scheme, contrast) {
        case (.dark, .increased): return 0.34
        case (.dark, _): return 0.20
        case (_, .increased): return 0.24
        default: return 0.12
        }
    }
}

/// 状态底色：tint 本身是动态系统色，alpha 再按环境分档。
struct AdaptiveTint<S: Shape>: ViewModifier {
    let tint: Color
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background(
            shape.fill(tint.opacity(AdaptiveAppearance.tintOpacity(scheme: scheme, contrast: contrast)))
        )
    }
}

/// 筛选 chip 的统一外观：选中用 accent 状态色，未选中用动态控件背景色，
/// 不再把 .secondary（前景语义色）当背景色用。
struct ChipBackground: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(
                Capsule().fill(selected
                    ? Color.accentColor.opacity(
                        AdaptiveAppearance.tintOpacity(scheme: scheme, contrast: contrast))
                    : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .clear))
    }
}

extension View {
    func adaptiveTint<S: Shape>(_ tint: Color, in shape: S) -> some View {
        modifier(AdaptiveTint(tint: tint, shape: shape))
    }

    func chipBackground(selected: Bool) -> some View {
        modifier(ChipBackground(selected: selected))
    }
}

// MARK: - 输入组件

/// 输入框容器：`.quaternary` / `.separator` 都是动态系统色，
/// 会随深浅色与「增加对比度」自动变化，不需要自定义 alpha。
struct FieldContainer: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.separator, lineWidth: 0.5)
            )
            .frame(minHeight: 30)
    }
}

/// 带标题与可选提示的普通文本输入行（用于无「选择…」按钮的字段）。
struct LabeledTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var hint: String? = nil
    var hintColor: Color = .secondary
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            TextField(placeholder, text: $text)
                .modifier(FieldContainer())
                .onSubmit { onSubmit?() }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(hintColor)
            }
        }
    }
}

/// 带标题与可选提示的密码输入行（用于 SESSDATA 等敏感字段）。
struct LabeledSecureField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var hint: String? = nil
    var hintColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            SecureField(placeholder, text: $text)
                .modifier(FieldContainer())
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(hintColor)
            }
        }
    }
}

/// 下拉选择行：与文本/密码输入行保持同一套「标题在上 + 圆角框」语言。
/// 折叠态用扁平 `FieldContainer` 框（带 chevron，无原生 bezel/三角）；
/// 展开态直接用系统原生 `Menu`，避免「一个控件两种观感」与焦点环/vibrancy 问题。
struct PickerOption<T: Hashable>: Identifiable {
    let id: T
    let label: String
}

struct LabeledPicker<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [PickerOption<T>]
    var hint: String? = nil
    var hintColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Menu {
                ForEach(options) { opt in
                    Button {
                        selection = opt.id
                    } label: {
                        if opt.id == selection {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                    .accessibilityAddTraits(opt.id == selection ? .isSelected : [])
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentLabel)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .modifier(FieldContainer())
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(currentLabel))
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(hintColor)
            }
        }
    }

    private var currentLabel: String {
        options.first(where: { $0.id == selection })?.label ?? "—"
    }
}

/// 路径输入行：标题在上，单行圆角输入框 + 右侧「文件夹」图标按钮，可选「自动发现」，底部状态提示。
/// 选择文件/目录通过 NSOpenPanel 完成，选中后直接写回绑定（经 `bind` 即时落库并推给引擎）。
struct PathInputRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let browse: BrowseTarget
    var showAutoDiscover: Bool = false
    var autoDiscover: (() -> Void)? = nil
    var hint: String? = nil
    var hintColor: Color = .secondary

    enum BrowseTarget {
        case file(message: String)
        case directory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .modifier(FieldContainer())
                browseButton
                if showAutoDiscover {
                    Button("自动发现") { autoDiscover?() }
                        .controlSize(.small)
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(hintColor)
            }
        }
    }

    private var browseButton: some View {
        Button(action: runBrowse) {
            Image(systemName: "folder")
        }
        .controlSize(.regular)
        .help("选择…")
        .accessibilityLabel(Text("选择…"))
    }

    private func runBrowse() {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        switch browse {
        case .file(let message):
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.message = message
        case .directory:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        }
        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
        }
    }
}

/// 轮询/超时等数值设置行：标题在左，右侧「值 + 步进器」，与表单内其它行（开关、下拉）对齐。
struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let display: (Int) -> String

    var body: some View {
        LabeledContent(title) {
            Stepper(value: $value, in: range, step: step) {
                Text(display(value))
            }
        }
    }
}
