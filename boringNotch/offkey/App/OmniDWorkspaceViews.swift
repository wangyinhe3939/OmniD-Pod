import AppKit
import SwiftUI

// Presentation only: the host owns data, permissions and persistence.
enum OmniDWorkspaceAction {
    case today, capture, shelf, router, cleaning, settings, search, quit, pin
    case dictate, save, project, reminder, showCompleted
    case chooseFiles, share, expandShelf, collapseShelf, media
}

struct OmniDWorkspaceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let completed: Bool
}

struct OmniDWorkspaceFile: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
}

struct OmniDWorkspaceIcon: Identifiable {
    let id: String
    let title: String
    let image: NSImage?
}

private let workspaceAccent = Color(red: 0.46, green: 0.38, blue: 0.96)

private struct WorkspaceAccentKey: EnvironmentKey { static let defaultValue = workspaceAccent }
private struct WorkspaceForegroundKey: EnvironmentKey { static let defaultValue = Color.white }
private struct WorkspaceTextScaleKey: EnvironmentKey { static let defaultValue = 1.0 }
private struct WorkspaceMaterialKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var workspaceAccentColor: Color { get { self[WorkspaceAccentKey.self] } set { self[WorkspaceAccentKey.self] = newValue } }
    var workspaceAccentForeground: Color { get { self[WorkspaceForegroundKey.self] } set { self[WorkspaceForegroundKey.self] = newValue } }
    var workspaceTextScale: Double { get { self[WorkspaceTextScaleKey.self] } set { self[WorkspaceTextScaleKey.self] = newValue } }
    var workspaceMaterial: Int { get { self[WorkspaceMaterialKey.self] } set { self[WorkspaceMaterialKey.self] = newValue } }
}

private struct WorkspaceFont: ViewModifier {
    @Environment(\.workspaceTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight))
    }
}

private extension View {
    func workspaceFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(WorkspaceFont(size: size, weight: weight))
    }
}

// Project-local shape hierarchy: near-square content, softly edged controls.
enum OmniDWorkspaceCorners {
    static let panel: CGFloat = 8
    static let content: CGFloat = 2
    static let control: CGFloat = 4
    static let folder: CGFloat = 6
}

enum OmniDWorkspaceSettingsSize {
    static let width: CGFloat = 390
    static let height: CGFloat = 600
}

enum OmniDWorkspaceTodaySize {
    static let size = NSSize(width: 320, height: 460)
}

enum OmniDWorkspaceWindowStyle {
    static func apply(_ window: NSWindow, material: Int) {
        let glass = material == 1 && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        window.isOpaque = !glass
        // A clear native frame detaches the title bar and loses the window corner mask.
        window.backgroundColor = glass ? .windowBackgroundColor : NSColor(name: "OmniDWorkspaceBackground") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
        }
        window.titlebarAppearsTransparent = !glass
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.cornerRadius = 10
            content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            content.layer?.masksToBounds = true
        }
    }
}

struct OmniDWorkspaceSurface<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.workspaceMaterial) private var material
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().workspaceFont(12).foregroundStyle(.primary)
            .background {
                if material == 1 && !reduceTransparency {
                    WorkspaceGlassBackdrop()
                        .overlay((scheme == .dark ? Color.black : .white).opacity(scheme == .dark ? 0.58 : 0.72))
                } else {
                    scheme == .dark ? Color.black : Color.white
                }
            }
    }
}

private struct WorkspaceGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// Secondary choices and confirmations use the system's dark glass, independent of the main page material.
extension View {
    func workspaceSecondarySurface() -> some View {
        self.background(.ultraThinMaterial).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }
    func workspaceTextAccent(_ color: Color) -> some View {
        background(WorkspaceTextAccent(color: NSColor(color)))
    }
    func workspaceNotice(_ title: String, isPresented: Binding<Bool>, message: String) -> some View {
        modifier(WorkspaceNotice(title: title, isPresented: isPresented, message: message))
    }
}

enum OmniDWorkspaceNotice {
    static func style(_ alert: NSAlert) {
        alert.window.appearance = NSAppearance(named: .darkAqua)
    }

    @MainActor
    static func confirm(_ title: String, message: String, confirmTitle: String,
                        window: NSWindow? = nil, action: @escaping () -> Void) {
        let owner = window ?? NSApp.keyWindow
        guard owner?.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        style(alert)
        if let owner {
            alert.beginSheetModal(for: owner) { response in
                if response == .alertFirstButtonReturn { action() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}

private struct WorkspaceNotice: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let message: String
    func body(content: Content) -> some View {
        content.onChange(of: isPresented, initial: true) { _, shown in
            guard shown else { return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            OmniDWorkspaceNotice.style(alert)
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { _ in isPresented = false }
            } else {
                alert.runModal()
                isPresented = false
            }
        }
    }
}

// SwiftUI's native menu highlight is system blue, not an arbitrary app accent.
// Keep app-owned choices in one compact, accessible second-level popover.
struct OmniDWorkspaceChoicePicker<Value: Hashable>: View {
    @Environment(\.workspaceAccentColor) private var accent
    @Environment(\.workspaceAccentForeground) private var foreground
    @State private var showingChoices = false
    let title: String
    @Binding var selection: Value
    let choices: [(String, Value)]
    var segmented = false
    var images: [Value: NSImage] = [:]

    var body: some View {
        if segmented {
            HStack(spacing: 2) {
                ForEach(choices.indices, id: \.self) { index in
                    Button { selection = choices[index].1 } label: {
                        Text(LocalizedStringKey(choices[index].0)).frame(maxWidth: .infinity)
                    }.buttonStyle(OmniDWorkspaceButtonStyle(selected: selection == choices[index].1))
                        .accessibilityLabel(Text(LocalizedStringKey(choices[index].0)))
                        .accessibilityAddTraits(selection == choices[index].1 ? .isSelected : [])
                }
            }.accessibilityElement(children: .contain).accessibilityLabel(title)
        } else {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer(minLength: 8)
                Button { showingChoices = true } label: {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(choices.first { $0.1 == selection }?.0 ?? "—"))
                            .lineLimit(2).multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    }.foregroundStyle(accent).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title)
                    .popover(isPresented: $showingChoices) {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(choices.indices, id: \.self) { index in
                                    let option = choices[index]
                                    Button { selection = option.1; showingChoices = false } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "checkmark").opacity(selection == option.1 ? 1 : 0)
                                            if let image = images[option.1] {
                                                Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                                            }
                                            Text(LocalizedStringKey(option.0)).fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                            .foregroundStyle(selection == option.1 ? foreground : Color.white)
                                            .background(selection == option.1 ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                    }.buttonStyle(.plain)
                                        .accessibilityAddTraits(selection == option.1 ? .isSelected : [])
                                }
                            }.padding(6)
                        }.frame(width: 220, height: CGFloat(min(choices.count * 34 + 12, 280)))
                            .workspaceSecondarySurface().onExitCommand { showingChoices = false }
                    }
            }
        }
    }
}

private struct WorkspaceTextAccent: NSViewRepresentable {
    let color: NSColor
    func makeNSView(context: Context) -> WorkspaceTextAccentView { WorkspaceTextAccentView() }
    func updateNSView(_ view: WorkspaceTextAccentView, context: Context) {
        view.color = color
        view.updateEditors()
    }
}

private final class WorkspaceTextAccentView: NSView {
    var color = NSColor.controlAccentColor
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        for name in [NSText.didBeginEditingNotification, NSControl.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(editingBegan), name: name, object: nil)
        }
        updateEditors()
    }
    @objc private func editingBegan(_ note: Notification) {
        guard (note.object as? NSView)?.window === window else { return }
        updateEditors()
    }
    func updateEditors() {
        guard let window else { return }
        (window.firstResponder as? NSTextView)?.insertionPointColor = color
        func update(_ view: NSView) {
            (view as? NSTextView)?.insertionPointColor = color
            view.subviews.forEach(update)
        }
        if let content = window.contentView { update(content) }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

// Flat controls: movement marks an action, not a simulated raised surface.
struct OmniDWorkspaceButtonStyle: ButtonStyle {
    @Environment(\.workspaceAccentColor) private var workspaceAccent
    @Environment(\.workspaceAccentForeground) private var accentForeground
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workspaceMaterial) private var material
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var prominent = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.workspaceFont(11, weight: .medium)
            .foregroundStyle(!enabled ? Color.secondary : prominent || selected ? accentForeground : Color.primary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(minHeight: 24)
            .background { background(pressed: configuration.isPressed) }
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder private func background(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.control)
        let color = (prominent || selected) && enabled ? workspaceAccent : Color.primary.opacity(enabled && pressed ? 0.12 : 0.07)
        if material == 1 && !reduceTransparency, #available(macOS 26, *) {
            shape.fill(color.opacity((prominent || selected) && enabled ? 1 : 0.5))
                .glassEffect(.regular.tint((prominent || selected) && enabled ? workspaceAccent : nil).interactive(enabled), in: shape)
        } else {
            shape.fill(color)
                .overlay { shape.strokeBorder(selected ? workspaceAccent : Color.primary.opacity(0.10), lineWidth: 0.5) }
        }
    }
}

struct OmniDWorkspacePin: View {
    @Environment(\.workspaceAccentColor) private var accent
    let pinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(pinned ? 0 : 45))
                .foregroundStyle(pinned ? accent : .secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pinned ? "取消置顶" : "置顶窗口")
        .accessibilityValue(pinned ? "已置顶" : "未置顶")
        .accessibilityAddTraits(pinned ? .isSelected : [])
        .help(pinned ? "已置顶；再次点击取消" : "置顶此窗口")
    }
}

struct OmniDWorkspaceToggleStyle: ToggleStyle {
    @Environment(\.workspaceAccentColor) private var accent
    @Environment(\.workspaceAccentForeground) private var accentForeground
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? accent : Color.primary.opacity(0.18))
                    .frame(width: 28, height: 16)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? accentForeground : .white)
                            .frame(width: 12, height: 12).padding(2)
                    }
                    .overlay { Capsule().strokeBorder(.primary.opacity(0.22), lineWidth: 0.5) }
                    .padding(.vertical, 4).contentShape(Rectangle())
                    .opacity(enabled ? 1 : 0.45)
            }.buttonStyle(.plain)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0), value: configuration.isOn)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}

struct OmniDWorkspaceWell: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.content, style: .continuous)
                .fill(Color(white: scheme == .dark ? 0.055 : 0.97))
                .overlay {
                    RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.content, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.5)
                }
        }
    }
}

struct OmniDPodSettingsPageMenu: View {
    let title: String
    var size: CGFloat = 16
    var weight: Font.Weight = .medium
    @ObservedObject private var navigation = OmniDPodSettingsNavigation.shared

    var body: some View {
        HStack(spacing: 6) {
        Text(title).workspaceFont(size, weight: weight).accessibilityAddTraits(.isHeader)
        Menu {
            Button("设置目录") { navigation.selection = nil }
            Divider()
            ForEach(OmniDPodSettingsPage.allCases) { page in
                Button { navigation.selection = page } label: {
                    Label(page.rawValue, systemImage: navigation.selection == page ? "checkmark" : page.icon)
                }
            }
        } label: {
            Image(systemName: "chevron.down").foregroundStyle(.secondary)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("设置页面导航，当前\(title)").help("点击标题切换设置页")
        }
    }
}

struct OmniDWorkspacePanelHeader: View {
    let title: String
    var onBack: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) { Image(systemName: "arrow.left") }
                    .buttonStyle(OmniDWorkspaceButtonStyle()).accessibilityLabel("返回设置目录")
            }
            if onBack != nil {
                OmniDPodSettingsPageMenu(title: title)
            } else {
                Text(title).workspaceFont(16, weight: .medium)
            }
            Spacer()
        }
    }
}

struct OmniDWorkspaceSettingsIndex: View {
    let onSelect: (String) -> Void
    let onClose: () -> Void
    private let pages = [
        ("外观", "paintpalette", "显示模式、颜色与 App 图标"),
        ("启动与行为", "gearshape", "常驻、显示器与手势"),
        ("快捷键", "command", "常用动作的键盘入口"),
        ("功能", "slider.horizontal.3", "媒体、托盘与系统提示"),
        ("灵动岛", "rectangle.topthird.inset.filled", "内容、动效与窗口行为"),
        ("权限与数据", "checkmark.shield", "提醒、键盘清洁与备份"),
        ("关于", "info.circle", "版本、GitHub 与许可"),
    ]

    var body: some View {
        OmniDWorkspaceSurface {
            VStack(alignment: .leading, spacing: 18) {
                OmniDWorkspacePanelHeader(title: "设置", onClose: onClose)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(pages, id: \.0) { page in
                            Button {
                                onSelect(page.0)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: page.1).frame(width: 20).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(page.0).workspaceFont(12, weight: .medium)
                                        Text(page.2).workspaceFont(10).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").workspaceFont(9).foregroundStyle(.secondary)
                                }.padding(.vertical, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityElement(children: .combine)
                            if page.0 != pages.last?.0 { Divider().opacity(0.4) }
                        }
                    }
                }
            }.padding(22)
        }.frame(width: OmniDWorkspaceSettingsSize.width, height: OmniDWorkspaceSettingsSize.height)
    }
}

private struct WorkspaceDrag: ViewModifier {
    let snapshot: Bool
    let provider: () -> NSItemProvider
    @ViewBuilder func body(content: Content) -> some View {
        if snapshot { content } else { content.onDrag(provider) }
    }
}

struct OmniDWorkspaceMenu: View {
    @Environment(\.workspaceAccentColor) private var workspaceAccent
    var logo: NSImage?
    let taskCount: Int
    let nextTask: String
    let fileCount: Int
    let cleaningStatus: String
    var mediaTitle: String?
    let onAction: (OmniDWorkspaceAction) -> Void

    var body: some View {
        OmniDWorkspaceSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    if let logo {
                        Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 25, height: 25).accessibilityHidden(true)
                    }
                    Text("OmniD-Pod").workspaceFont(14, weight: .semibold)
                    Spacer()
                    Button { onAction(.search) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(OmniDWorkspaceButtonStyle()).accessibilityLabel("搜索应用内动作")
                }
                Button { onAction(.today) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checklist").workspaceFont(19, weight: .light)
                            .foregroundStyle(workspaceAccent).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("今日").workspaceFont(14, weight: .medium)
                                Spacer()
                                Text("\(taskCount)").workspaceFont(11, weight: .semibold)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(workspaceAccent.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.content))
                            }
                            Text(nextTask.isEmpty ? "今天要做什么？" : nextTask)
                                .workspaceFont(11).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(15).modifier(OmniDWorkspaceWell())
                }
                .buttonStyle(.plain).accessibilityElement(children: .combine)
                VStack(spacing: 0) {
                    row("随手记", symbol: "square.and.pencil", detail: "文字 · 粘贴 · 听写", action: .capture)
                    Divider().opacity(0.45).padding(.leading, 38)
                    row("暂存文件", symbol: "tray", detail: "\(fileCount) 个文件", action: .shelf)
                    if DDOptionalNativeSlot.shared.factory != nil {
                        Divider().opacity(0.45).padding(.leading, 38)
                        row("万有引力", symbol: "archivebox", detail: "万物索引与归档", action: .router)
                    }
                    Divider().opacity(0.45).padding(.leading, 38)
                    row("键盘清洁", symbol: "keyboard", detail: cleaningStatus, action: .cleaning)
                }
                if let mediaTitle, !mediaTitle.isEmpty {
                    row("正在播放", symbol: "music.note", detail: mediaTitle, action: .media)
                }
                HStack {
                    Button { onAction(.settings) } label: { Label("设置", systemImage: "gearshape") }
                        .buttonStyle(OmniDWorkspaceButtonStyle())
                        .keyboardShortcut(",", modifiers: .command)
                    Spacer()
                    Button("退出") { onAction(.quit) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .keyboardShortcut("q", modifiers: .command)
                }
                .workspaceFont(11)
            }
            .padding(14)
        }
        .frame(width: 290)
    }

    private func row(_ title: String, symbol: String, detail: String, action: OmniDWorkspaceAction) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).workspaceFont(18, weight: .light)
                    .frame(width: 24).accessibilityHidden(true)
                Text(title).workspaceFont(12, weight: .medium)
                Spacer(minLength: 8)
                Text(detail).workspaceFont(10).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").workspaceFont(8).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityElement(children: .combine)
    }
}

struct OmniDWorkspaceToday: View {
    @Environment(\.workspaceAccentColor) private var workspaceAccent
    @FocusState private var editorFocused: Bool
    @Namespace private var tabSelection
    @Binding var draft: String
    @Binding var tab: Int
    let dateLabel: String
    let tasks: [OmniDWorkspaceTask]
    let persistenceStatus: String
    var projectLabel = "项目"
    var reminderLabel = "提醒"
    var pinned = false
    var showingCompleted = false
    var onBatchSave: (() -> Void)?
    var onRecordAction: ((String, String) -> Void)?
    var renderingSnapshot = false
    let onAction: (OmniDWorkspaceAction) -> Void
    let onToggle: (String) -> Void

    var body: some View {
        OmniDWorkspaceSurface {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tab == 0 ? "今日" : "灵感").workspaceFont(17, weight: .medium)
                        Text(dateLabel).workspaceFont(10).foregroundStyle(.secondary)
                    }
                    Spacer()
                    OmniDWorkspacePin(pinned: pinned) { onAction(.pin) }
                }
                HStack(spacing: 6) {
                    tabButton("待办", index: 0)
                    tabButton("灵感", index: 1)
                    Spacer()
                    Text("\(tasks.filter { !$0.completed }.count) 待完成")
                        .workspaceFont(10).foregroundStyle(.secondary)
                }
                .padding(6).modifier(OmniDWorkspaceWell())
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 10) {
                        // ImageRenderer cannot draw AppKit text controls. Only PNG
                        // exports use Text; the actual UI always uses TextField.
                        if renderingSnapshot {
                            Text(draft.isEmpty ? "写一句，粘贴一段，或听写…" : draft)
                                .foregroundStyle(draft.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        } else {
                            TextField("写一句，粘贴一段，或听写…", text: $draft, axis: .vertical)
                                .textFieldStyle(.plain).lineLimit(6...8)
                                .frame(minHeight: 96, alignment: .topLeading)
                                .focused($editorFocused)
                                .accessibilityLabel("灵感或待办内容")
                        }
                        Button { editorFocused = true; onAction(.dictate) } label: { Image(systemName: "mic") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("使用系统听写，文字输入仍可用").accessibilityLabel("系统听写")
                    }
                    HStack(spacing: 13) {
                        Button { onAction(.project) } label: { Label(projectLabel, systemImage: "tag") }
                        Button { onAction(.reminder) } label: { Label(reminderLabel, systemImage: "bell") }
                            .disabled(tab != 0)
                        Spacer()
                        Button("记下") { onAction(.save) }
                            .buttonStyle(OmniDWorkspaceButtonStyle(prominent: true))
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut("s", modifiers: .command)
                            .contextMenu {
                                if let onBatchSave {
                                    Button("将每一行分别记下…", action: onBatchSave)
                                }
                            }
                    }
                    .workspaceFont(10).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(15).modifier(OmniDWorkspaceWell())
                if !tasks.isEmpty { ScrollView { taskRows }.frame(maxHeight: .infinity) }
                else { Spacer(minLength: 0) }
                HStack {
                    Label(persistenceStatus, systemImage: "externaldrive")
                    Spacer()
                    Button(showingCompleted ? "隐藏已完成" : "已完成") { onAction(.showCompleted) }.buttonStyle(.plain)
                        .disabled(tab != 0)
                }
                .workspaceFont(9).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: OmniDWorkspaceTodaySize.size.width, height: OmniDWorkspaceTodaySize.size.height)
        .workspaceTextAccent(workspaceAccent)
        .onAppear { editorFocused = true }
    }

    private var taskRows: some View {
        VStack(spacing: 0) {
            ForEach(tasks) { task in
                HStack(alignment: .top, spacing: 12) {
                    Button { onToggle(task.id) } label: {
                        Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                            .workspaceFont(17, weight: .light)
                            .foregroundStyle(task.completed ? Color.secondary : workspaceAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab == 1 ? "转为今日待办：\(task.title)" : task.completed ? "恢复待办：\(task.title)" : "完成：\(task.title)")
                    VStack(alignment: .leading, spacing: 7) {
                        Text(task.title).workspaceFont(12).strikethrough(task.completed)
                        Text(task.detail).workspaceFont(10).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .transition(.opacity.combined(with: .offset(y: 4)))
                .contextMenu {
                    if let onRecordAction {
                        Button("复制原文") { onRecordAction(task.id, "copy") }
                        Button("编辑原文…") { onRecordAction(task.id, "edit") }
                        if tab == 0 {
                            Button("设定提醒…") { onRecordAction(task.id, "reminder") }
                            Button("移到明天") { onRecordAction(task.id, "tomorrow") }
                            Button("取消日期") { onRecordAction(task.id, "undated") }
                        }
                    }
                }
                if task.id != tasks.last?.id { Divider().opacity(0.45) }
            }
        }
        .animation(.easeOut(duration: 0.18), value: tasks.map { "\($0.id):\($0.completed)" })
    }

    private func tabButton(_ title: String, index: Int) -> some View {
        Button { tab = index } label: {
            Text(title).workspaceFont(11, weight: .medium)
                .foregroundStyle(tab == index ? Color.primary : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background {
                    if tab == index {
                        RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.control)
                            .fill(workspaceAccent.opacity(0.16)).matchedGeometryEffect(id: "tab", in: tabSelection)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.control))
                            .overlay(alignment: .bottom) { Rectangle().fill(workspaceAccent).frame(height: 2) }
                    }
                }
        }
        .buttonStyle(.plain).accessibilityAddTraits(tab == index ? .isSelected : [])
        .animation(.spring(duration: 0.22, bounce: 0.06), value: tab)
    }
}

// A vector UI container, not a substituted illustration or brand asset.
private struct OmniDWorkspaceFolderFront: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = OmniDWorkspaceCorners.folder
        var p = Path()
        p.move(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
        p.addLine(to: CGPoint(x: w * 0.36, y: 0))
        p.addCurve(to: CGPoint(x: w * 0.52, y: 16),
                   control1: CGPoint(x: w * 0.43, y: 0), control2: CGPoint(x: w * 0.43, y: 16))
        p.addLine(to: CGPoint(x: w - r, y: 16))
        p.addQuadCurve(to: CGPoint(x: w, y: 16 + r), control: CGPoint(x: w, y: 16))
        p.addLine(to: CGPoint(x: w, y: h - r))
        p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}

private struct OmniDWorkspaceFolder: View {
    let count: Int
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 1, green: 0.79, blue: 0.52),
                                    Color(red: 0.99, green: 0.46, blue: 0.43),
                                    Color(red: 0.88, green: 0.27, blue: 0.83)],
                           startPoint: .topLeading, endPoint: .trailing)
            OmniDWorkspaceFolderFront().fill(Color(white: 0.04)).frame(height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text("暂存文件").workspaceFont(10, weight: .medium)
                Text("随手放下，随时取用").workspaceFont(8).foregroundStyle(.white.opacity(0.56))
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%02d", count)).workspaceFont(20, weight: .bold)
                    Text("个文件").workspaceFont(9).foregroundStyle(.white.opacity(0.70))
                    Spacer()
                    Image(systemName: "arrow.up.right").workspaceFont(12)
                }
            }
            .padding(10).frame(height: 96).foregroundStyle(.white)
        }
        .frame(width: 148, height: 116)
        .clipShape(RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.folder, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.folder, style: .continuous)
                .strokeBorder(.black.opacity(0.85), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct OmniDWorkspaceShelf: View {
    let files: [OmniDWorkspaceFile]
    let expanded: Bool
    var pinned = false
    var onFileAction: ((String, String) -> Void)?
    var fileProvider: ((String) -> NSItemProvider)?
    var drop: (([NSItemProvider]) -> Bool)?
    var status: String?
    var renderingSnapshot = false
    let onAction: (OmniDWorkspaceAction) -> Void

    @ViewBuilder var body: some View {
        if renderingSnapshot { shelfContent }
        else { shelfContent.onDrop(of: ["public.file-url"], isTargeted: nil) { drop?($0) ?? false } }
    }

    private var shelfContent: some View {
        OmniDWorkspaceSurface {
            VStack(alignment: .leading, spacing: files.isEmpty ? 12 : 18) {
                HStack(spacing: 10) {
                    if expanded {
                        Button { onAction(.collapseShelf) } label: { Image(systemName: "arrow.left") }
                            .buttonStyle(OmniDWorkspaceButtonStyle()).accessibilityLabel("返回缩略图")
                    }
                    Text("暂存文件").workspaceFont(13, weight: .medium)
                    Spacer()
                    OmniDWorkspacePin(pinned: pinned) { onAction(.pin) }
                    Button { onAction(.chooseFiles) } label: { Image(systemName: "plus") }
                        .buttonStyle(OmniDWorkspaceButtonStyle()).accessibilityLabel("选择文件")
                }
                if files.isEmpty {
                    Text("拖入文件，或点 + 选择")
                        .workspaceFont(11).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                } else if expanded {
                    if renderingSnapshot { fileRows }
                    else { ScrollView { fileRows }.frame(maxHeight: 290) }
                } else {
                    Button { onAction(.expandShelf) } label: {
                        OmniDWorkspaceFolder(count: files.count).frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.plain).accessibilityLabel("展开 \(files.count) 个暂存文件")
                    HStack(spacing: 9) {
                        ForEach(files.prefix(3)) { file in
                          Button { onFileAction?(file.id, "preview") } label: {
                            VStack(spacing: 7) {
                                Image(systemName: file.symbol).workspaceFont(21, weight: .light)
                                    .frame(maxWidth: .infinity).frame(height: 39)
                                Text(file.name).workspaceFont(9).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 8).modifier(OmniDWorkspaceWell())
                          }
                          .buttonStyle(.plain)
                          .modifier(WorkspaceDrag(snapshot: renderingSnapshot, provider: { fileProvider?(file.id) ?? NSItemProvider() }))
                          .help("点击或按空格预览；可拖出原文件引用")
                          .contextMenu {
                              if let onFileAction {
                                  Button("预览") { onFileAction(file.id, "preview") }
                                  Button("移除暂存引用") { onFileAction(file.id, "remove") }
                              }
                          }
                        }
                    }
                }
                HStack {
                    Text("仅引用，不复制原文件").workspaceFont(9).foregroundStyle(.secondary)
                    Spacer()
                    Button { onAction(.share) } label: { Label("分享", systemImage: "square.and.arrow.up") }
                        .buttonStyle(OmniDWorkspaceButtonStyle(prominent: true)).disabled(files.isEmpty)
                }
                if let status, !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(14)
        }
        .frame(width: expanded && !files.isEmpty ? 330 : 280)
    }

    private var fileRows: some View {
        VStack(spacing: 0) {
            ForEach(files) { file in
                Button { onFileAction?(file.id, "preview") } label: {
                    HStack(spacing: 13) {
                        Image(systemName: file.symbol).workspaceFont(22, weight: .light)
                            .frame(width: 38, height: 43)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.content))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.name).workspaceFont(12).lineLimit(1)
                            Text(file.detail).workspaceFont(9).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击或按空格预览；可拖出原文件引用")
                .modifier(WorkspaceDrag(snapshot: renderingSnapshot, provider: { fileProvider?(file.id) ?? NSItemProvider() }))
                .contextMenu {
                    if let onFileAction {
                        Button("预览") { onFileAction(file.id, "preview") }
                        Button("在 Finder 中显示") { onFileAction(file.id, "reveal") }
                        Button("移除暂存引用") { onFileAction(file.id, "remove") }
                    }
                }
                if file.id != files.last?.id { Divider().opacity(0.4) }
            }
        }
    }
}

struct OmniDWorkspaceAppearance: View {
    @Environment(\.workspaceAccentColor) private var workspaceAccent
    @Environment(\.workspaceAccentForeground) private var accentForeground
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var showingPalette = false
    @Binding var mode: Int
    @Binding var palette: ONEAccentPalette
    @Binding var reduceMotion: Bool
    @Binding var textScale: Double
    var material: Binding<Int> = .constant(0)
    var usingPalette = true
    var customAccent: Binding<Color>?
    var onResetAccent: (() -> Void)?
    var icons: [OmniDWorkspaceIcon] = []
    var selectedIcon = ""
    var onIconSelect: ((String) -> Void)?
    var onBack: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        OmniDWorkspaceSurface {
            VStack(alignment: .leading, spacing: 0) {
                header
                separator.padding(.top, 12).padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        displaySection
                        separator.padding(.vertical, 10)
                        accentSection
                        separator.padding(.vertical, 10)
                        HStack(spacing: 12) {
                            Label("文字大小", systemImage: "textformat")
                            Spacer(minLength: 8)
                            Slider(value: $textScale, in: 1...1.3)
                                .controlSize(.mini).frame(width: 104)
                                .accessibilityLabel("文字大小")
                                .accessibilityValue("\(Int(textScale * 100))%")
                            Text("\(Int(textScale * 100))%").workspaceFont(11)
                                .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        }.workspaceFont(13).frame(minHeight: 26)
                        separator.padding(.vertical, 10)
                        HStack {
                            Label("减少动态效果", systemImage: "circle.dotted")
                            Spacer()
                            Toggle("减少动态效果", isOn: $reduceMotion)
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }.workspaceFont(13).frame(minHeight: 26)
                        if !icons.isEmpty {
                            separator.padding(.top, 12).padding(.bottom, 10)
                            iconSection
                        }
                        Text("立即生效，仅调整 App；不会改变 Mac 的系统外观。")
                            .workspaceFont(10.5).foregroundStyle(.secondary).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .frame(width: OmniDWorkspaceSettingsSize.width, height: OmniDWorkspaceSettingsSize.height)
    }

    // Only this page adopts the approved proportions; other workspace headers stay unchanged.
    private var header: some View {
        HStack(spacing: 14) {
            if let onBack {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(OmniDWorkspaceButtonStyle()).accessibilityLabel("返回设置目录")
            }
            OmniDPodSettingsPageMenu(title: "外观", size: 20, weight: .semibold)
            Spacer()
        }.frame(minHeight: 28)
    }

    private var separator: some View { Divider().opacity(0.55) }

    private var selectionAnimation: Animation? {
        reduceMotion || systemReduceMotion ? nil : .easeOut(duration: 0.16)
    }

    private var selectionMark: some View {
        Image(systemName: "checkmark").workspaceFont(8, weight: .bold)
            .foregroundStyle(accentForeground).frame(width: 15, height: 15)
            .background(workspaceAccent, in: Circle()).accessibilityHidden(true)
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("显示模式", systemImage: "sun.max").workspaceFont(13).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                appearanceChoice("浅色", index: 0)
                appearanceChoice("深色", index: 1)
                appearanceChoice("随系统", index: 2)
            }.animation(selectionAnimation, value: mode)
            HStack {
                Text("材质").workspaceFont(13)
                Spacer()
                OmniDWorkspaceChoicePicker(title: "材质", selection: material,
                    choices: [("纯色", 0), ("液态玻璃", 1)], segmented: true).frame(width: 156)
            }.frame(minHeight: 26)
        }
    }

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Label("强调色", systemImage: "paintpalette").workspaceFont(13)
                Spacer(minLength: 8)
                ForEach(ONEAccentPalette.featuredCases) { color in
                    Button { palette = color } label: {
                        Circle().fill(Color(nsColor: NSColor(oneHex: color.accentHex)))
                            .frame(width: 21, height: 21)
                            .overlay {
                                if usingPalette && palette == color {
                                    Image(systemName: "checkmark").workspaceFont(9, weight: .bold)
                                        .foregroundStyle(Color(nsColor: NSColor(oneHex: color.foregroundHex)))
                                }
                            }
                            .overlay { Circle().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5) }
                            .overlay {
                                if usingPalette && palette == color {
                                    Circle().strokeBorder(workspaceAccent, lineWidth: 1.2).padding(-3)
                                }
                            }
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("\(color.title) · \(color.hexLabel)")
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(usingPalette && palette == color ? .isSelected : [])
                }
                Button { showingPalette = true } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("更多 ONE 色卡颜色").accessibilityLabel("更多 ONE 色卡颜色")
                .popover(isPresented: $showingPalette, arrowEdge: .trailing) {
                    OmniDWorkspacePalettePicker(palette: $palette, usingPalette: usingPalette,
                                               customAccent: customAccent, onResetAccent: onResetAccent,
                                               onSelect: { showingPalette = false })
                        .workspaceSecondarySurface()
                }
            }.animation(selectionAnimation, value: palette)
            Text("只标记选择与主要动作，不改变普通文字颜色。")
                .workspaceFont(10.5).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App 图标").workspaceFont(13)
            HStack(alignment: .top, spacing: 10) {
                ForEach(icons) { icon in
                    Button { onIconSelect?(icon.id) } label: {
                        VStack(spacing: 7) {
                            Group {
                                if let image = icon.image {
                                    Image(nsImage: image).resizable().scaledToFit()
                                        .frame(width: 52, height: 52)
                                }
                            }
                            .frame(maxWidth: .infinity).frame(height: 64)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(selectedIcon == icon.id ? workspaceAccent : .clear, lineWidth: 1.2)
                            }
                            .overlay(alignment: .topTrailing) {
                                if selectedIcon == icon.id { selectionMark.padding(4) }
                            }
                            Text(icon.title).workspaceFont(11)
                                .foregroundStyle(selectedIcon == icon.id ? Color.primary : Color.secondary)
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(icon.title) App 图标")
                    .accessibilityAddTraits(selectedIcon == icon.id ? .isSelected : [])
                }
            }.animation(selectionAnimation, value: selectedIcon)
        }
    }

    private func appearanceChoice(_ title: String, index: Int) -> some View {
        Button { mode = index } label: {
            VStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 3) {
                        ForEach(0..<3) { _ in Circle().fill(.gray.opacity(0.55)).frame(width: 3, height: 3) }
                    }
                    HStack(spacing: 9) {
                        Circle().fill(.gray.opacity(0.4)).frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(.gray.opacity(0.65)).frame(width: 17, height: 3)
                            Capsule().fill(.gray.opacity(0.25)).frame(height: 3)
                            Capsule().fill(.gray.opacity(0.25)).frame(height: 3)
                        }
                    }
                }
                .padding(9).frame(maxWidth: .infinity).frame(height: 56)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(
                            colors: index == 0 ? [Color(white: 0.94), .white]
                                : index == 1 ? [Color(white: 0.20), Color(white: 0.08)]
                                : [Color(white: 0.90), Color(white: 0.16)],
                            startPoint: .leading, endPoint: .trailing))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(mode == index ? workspaceAccent : Color.primary.opacity(0.16),
                                      lineWidth: mode == index ? 1.5 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if mode == index { selectionMark.padding(5) }
                }
                Text(title).workspaceFont(11, weight: mode == index ? .medium : .regular)
                    .foregroundStyle(mode == index ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain).frame(maxWidth: .infinity)
        .accessibilityLabel("\(title)模式").accessibilityAddTraits(mode == index ? .isSelected : [])
    }
}

struct OmniDWorkspacePalettePicker: View {
    @Binding var palette: ONEAccentPalette
    var usingPalette = true
    var customAccent: Binding<Color>?
    var onResetAccent: (() -> Void)?
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 10) {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 3), spacing: 8) {
            ForEach(ONEAccentPalette.card07Cases) { color in
                Button {
                    palette = color
                    onSelect()
                } label: {
                    Circle().fill(Color(nsColor: NSColor(oneHex: color.accentHex)))
                        .frame(width: 22, height: 22)
                        .overlay {
                            if usingPalette && palette == color {
                                Image(systemName: "checkmark").workspaceFont(9, weight: .bold)
                                    .foregroundStyle(Color(nsColor: NSColor(oneHex: color.foregroundHex)))
                            }
                        }
                        .overlay { Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.7) }
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("\(color.title) · \(color.hexLabel)")
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(usingPalette && palette == color ? .isSelected : [])
            }
        }
        if customAccent != nil || onResetAccent != nil {
            Divider()
            if let customAccent {
                ColorPicker("自定义", selection: customAccent, supportsOpacity: false).controlSize(.small)
            }
            if let onResetAccent {
                Button("中性色") { onResetAccent(); onSelect() }.buttonStyle(.plain)
            }
        }
        }.workspaceFont(11).padding(10).frame(width: 114)
        .onExitCommand(perform: onSelect)
    }
}
