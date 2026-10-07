import AppKit
import AVFoundation
import Defaults
import SwiftUI

enum OmniDPodStyle {
    static let background = Color(white: 0.105)
    static let sidebar = Color(white: 0.075)
    static let surface = Color(white: 0.16)
    static let accent = Color(white: 0.58)
}

struct OmniDPodPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.omniDAccentTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isEnabled ? (theme.isCustom ? theme.foreground : .black) : Color.primary.opacity(0.4))
            .padding(.horizontal, 9).padding(.vertical, 5).frame(minHeight: 24)
            .background(isEnabled ? (theme.isCustom ? theme.accent.opacity(configuration.isPressed ? 0.8 : 1) : Color(white: configuration.isPressed ? 0.72 : 0.94)) : OmniDPodStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: OmniDWorkspaceCorners.control))
    }
}

struct OmniDPodBrand: View {
    var compact = false
    var body: some View {
        HStack(spacing: 8) {
            Image("DDMenuBar").renderingMode(.template).resizable().scaledToFit()
                .frame(width: compact ? 28 : 44, height: compact ? 28 : 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("OmniD-Pod").font(.system(size: compact ? 13 : 17, weight: .semibold)).lineLimit(1)
                if !compact { Text("DoubleOne").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

enum OmniDPodAppIconVariant: String, CaseIterable, Identifiable {
    // Preserve the existing saved default choice while replacing its artwork.
    case smile = "orange", flat, gradient, macOS

    var id: String { rawValue }
    var title: String {
        switch self {
        case .smile: "黑色"
        case .flat: "极简白"
        case .gradient: "渐变色"
        case .macOS: "macOS"
        }
    }
    var assetName: String {
        switch self {
        case .smile: "AppIcon"
        case .flat: "OmniDIconFlat"
        case .gradient: "OmniDIconGradient"
        case .macOS: "OmniDIconMacOS"
        }
    }
    var image: NSImage? {
        Bundle.main.url(forResource: assetName, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }
}

@MainActor
enum OmniDPodAppIcon {
    static let preferenceKey = "omnid.appIconVariant"

    static func applyStored() {
        let stored = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
        apply(OmniDPodAppIconVariant(rawValue: stored) ?? .smile)
    }

    static func apply(_ variant: OmniDPodAppIconVariant) {
        guard let image = variant.image else { return }
        NSApp.applicationIconImage = image
    }
}

struct OmniDPodMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @Default(.boringShelf) private var shelfEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                Image("DDLogo").resizable().scaledToFit().frame(width: 24, height: 24)
                Text("OmniD-Pod")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.bottom, 7)
            Divider().padding(.bottom, 3)
            OmniDPodMenuRow("播放", icon: "play.fill") { perform { BoringViewCoordinator.shared.showNotch(.home) } }
            if shelfEnabled {
                OmniDPodMenuRow("文件暂存", icon: "tray.full") { perform { BoringViewCoordinator.shared.showNotch(.shelf) } }
            }
            OmniDPodMenuRow("工具…", icon: "square.grid.2x2.fill") { perform { OffKeyWindowCoordinator.shared.showLauncher() } }
            Divider().padding(.vertical, 3)
            OmniDPodMenuRow("设置", icon: "gearshape") { perform { SettingsWindowController.shared.showWindow() } }
                .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            Divider().padding(.vertical, 3)
            OmniDPodMenuRow("重新启动 OmniD-Pod", icon: "arrow.clockwise") { perform { ApplicationRelauncher.restart() } }
            OmniDPodMenuRow("退出", icon: "power") { perform { NSApp.terminate(nil) } }
                .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
        .padding(10)
        .frame(width: 240)
        .background(OmniDPodStyle.sidebar)
        .foregroundStyle(Color.white)
        .preferredColorScheme(.dark)
    }

    private func perform(_ action: () -> Void) {
        dismiss()
        action()
    }
}

private struct OmniDPodMenuRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.96))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(height: 31)
            .contentShape(Rectangle())
            .background(hovering ? OmniDPodStyle.surface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct OmniDPodLauncherView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OmniDPodBrand(compact: true).padding(.bottom, 6)
            Divider()
            OmniDPodLauncherRow(title: "快速命名", icon: "character.cursor.ibeam", action: OffKeyWindowCoordinator.shared.showNaming)
            OmniDPodLauncherRow(title: "键盘清洁", icon: "keyboard", action: OffKeyWindowCoordinator.shared.showCleaning)
            OmniDPodLauncherRow(title: "记事", icon: "note.text", action: OffKeyWindowCoordinator.shared.showNotes)
            Divider()
            OmniDPodLauncherRow(title: "设置", icon: "gearshape", action: SettingsWindowController.shared.showWindow)
            Spacer(minLength: 0)
        }
        .padding(16).frame(width: 264, height: 292)
        .background(OmniDPodStyle.sidebar).preferredColorScheme(.dark)
    }
}

private struct OmniDPodLauncherRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
            .background(hovering ? OmniDPodStyle.surface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// Tool actions stay separate from playback. Text entry opens a key window.
struct OmniDPodNotchActions: View {
    @ObservedObject private var cleaning = OffKeyCleaningController.shared
    @Environment(\.omniDAccentTheme) private var theme
    var body: some View {
        HStack(spacing: 8) {
            tool("快速命名", icon: "character.cursor.ibeam", action: OffKeyWindowCoordinator.shared.showNaming)
                .disabled(cleaning.isCleaning)
            tool(cleaning.isCleaning ? "恢复键盘" : "键盘清洁", icon: "keyboard", action: OffKeyWindowCoordinator.shared.showCleaning)
            tool("记事", icon: "note.text", action: OffKeyWindowCoordinator.shared.showNotes)
                .disabled(cleaning.isCleaning)
            if DDOptionalNativeSlot.shared.factory != nil {
                tool("万有引力", icon: "archivebox") { OffKeyWindowCoordinator.shared.performWorkspaceAction(.router) }
                    .disabled(cleaning.isCleaning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private func tool(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 21, weight: .regular))
                    .foregroundStyle(theme.isCustom ? theme.readableAccent : .primary)
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 74)
            .background(OmniDPodStyle.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

enum OmniDPodSettingsPage: String, CaseIterable, Identifiable {
    case general = "启动与行为"
    case shortcuts = "快捷键"
    case features = "功能"
    case appearance = "外观"
    case notch = "灵动岛"
    case privacy = "权限与数据"
    case about = "关于"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .features: "square.grid.2x2"
        case .appearance: "paintbrush"
        case .notch: "rectangle.topthird.inset.filled"
        case .privacy: "checkmark.shield"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class OmniDPodSettingsNavigation: ObservableObject {
    static let shared = OmniDPodSettingsNavigation()
    @Published var selection: OmniDPodSettingsPage?
}


struct SettingsView: View {
    @ObservedObject private var navigation = OmniDPodSettingsNavigation.shared
    var body: some View {
        Group {
            if navigation.selection == .appearance {
                // Appearance is this window's content, never a panel inside another settings page.
                OmniDWorkspaceAppearanceHost(onBack: { navigation.selection = nil },
                                             onClose: { SettingsWindowController.shared.close() })
            } else if let page = navigation.selection {
                OmniDWorkspaceSurface {
                    VStack(alignment: .leading, spacing: 14) {
                        OmniDWorkspacePanelHeader(title: page.rawValue, onBack: { navigation.selection = nil },
                                                  onClose: { SettingsWindowController.shared.close() })
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .scrollContentBackground(.hidden)
                    }.padding(18)
                }
                .id(page).transition(.opacity.combined(with: .offset(x: 8)))
            } else {
                OmniDWorkspaceSettingsIndex(onSelect: { title in
                    navigation.selection = OmniDPodSettingsPage(rawValue: title)
                }, onClose: { SettingsWindowController.shared.close() })
                    .transition(.opacity)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(OmniDWorkspaceToggleStyle())
        .font(.system(size: 11)).controlSize(.small)
        .frame(width: OmniDWorkspaceSettingsSize.width, height: OmniDWorkspaceSettingsSize.height, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: navigation.selection)
        .onExitCommand {
            if navigation.selection == nil { SettingsWindowController.shared.close() }
            else { navigation.selection = nil }
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection {
        case .general: GeneralSettings()
        case .shortcuts: Shortcuts()
        case .features: OmniDPodFeatureSettings()
        case .appearance: EmptyView() // Rendered directly above, without a second shell.
        case .notch: OmniDPodNotchSettings()
        case .privacy: OmniDPodPrivacySettings()
        case .about: OmniDPodAboutView()
        case nil: EmptyView()
        }
    }
}

private struct OmniDPodFeatureSettings: View {
    @State private var page = "媒体"
    private let pages = ["媒体", "文件", "日历", "电池", "提示"]
    var body: some View {
        VStack(spacing: 0) {
            OmniDWorkspaceChoicePicker(title: "功能分类", selection: $page,
                choices: pages.map { ($0, $0) }, segmented: true).padding(.horizontal, 18).padding(.bottom, 6)
            Group {
                switch page {
                case "媒体": Media()
                case "日历": CalendarSettings()
                case "电池": Charge()
                case "提示": HUD()
                default: Shelf()
                }
            }
        }
    }
}

private struct OmniDPodNotchSettings: View {
    @State private var page = 0
    var body: some View {
        VStack(spacing: 0) {
            OmniDWorkspaceChoicePicker(title: "灵动岛设置分类", selection: $page,
                choices: [("内容与动效", 0), ("窗口行为", 1)], segmented: true)
                .padding(.horizontal, 18).padding(.bottom, 6)
            if page == 0 { Appearance() } else { Advanced() }
        }
    }
}

private struct OmniDPodPrivacySettings: View {
    @State private var page = "提醒"
    @ObservedObject private var cleaning = OffKeyCleaningController.shared
    @ObservedObject private var notes = OffKeyWindowCoordinator.shared.notesStore
    private var pages: [String] {
        ["提醒"] + (DDOptionalNativeSlot.shared.factory == nil ? [] : ["万有引力"]) + ["系统权限", "数据"]
    }
    var body: some View {
        VStack(spacing: 0) {
        OmniDWorkspaceChoicePicker(title: "权限与数据分类", selection: $page,
            choices: pages.map { ($0, $0) }, segmented: true)
            .padding(.horizontal, 18).padding(.bottom, 6)
        if page == "万有引力", let factory = DDOptionalNativeSlot.shared.factory {
            DDNativeSlotSettings(factory: factory).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        Form {
            if page == "提醒" {
            OmniDWorkspaceReminderSettings(notes: OffKeyWindowCoordinator.shared.notesStore)
            }
            if page == "系统权限" {
            Section("键盘清洁权限") {
                LabeledContent("辅助功能", value: cleaning.accessibilityGranted ? "已允许" : "未允许")
                LabeledContent("输入监控", value: cleaning.inputMonitoringGranted ? "已允许" : "未允许")
                HStack {
                    if !cleaning.hasPermissions {
                        Button(cleaning.permissionActionTitle) { cleaning.requestPermissions() }
                            .accessibilityHint("打开下一项尚未允许的系统权限设置")
                    }
                    Button("刷新状态") { cleaning.refreshPermissions() }
                }
                if let message = cleaning.permissionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(cleaning.hasPermissions ? .secondary : .orange)
                }
                Text("两项权限均允许后才能锁定键盘；鼠标与触控板不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("替换系统提示浮层只需要辅助功能权限；启用与状态测试在“功能 → 提示”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            if page == "数据" {
            Section("记事备份") {
                OffKeyNotesTransferControls(store: notes)
                Text("数据仅保存在本机。替换导入前会备份当前记录。")
                    .font(.caption).foregroundStyle(.secondary)
                if !notes.statusMessage.isEmpty {
                    Text(notes.statusMessage).font(.caption)
                        .foregroundStyle(notes.hasUnsavedChanges ? .orange : .secondary)
                }
            }
            Section("文件访问") {
                Button("管理命名目录…") { OffKeyWindowCoordinator.shared.showNaming() }
                Text("仅访问你选择的文件和文件夹。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
        }
        }
        }
        .onAppear { cleaning.refreshPermissions() }
        .workspaceNotice("记事", isPresented: Binding(get: { notes.presentedError != nil }, set: { if !$0 { notes.presentedError = nil } }),
            message: notes.presentedError ?? "")
    }
}

private struct OmniDPodAboutView: View {
    @AppStorage("omnid.workspace.githubURL") private var githubURL = "https://github.com/wangyinhe3939"
    private var githubLink: URL? {
        let address = githubURL.isEmpty ? "https://github.com/wangyinhe3939" : githubURL
        guard let url = URL(string: address), url.scheme == "https", url.host?.lowercased() == "github.com",
              !url.path.isEmpty, url.path != "/" else { return nil }
        return url
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OmniDPodBrand()
                Divider()
                LabeledContent("作者", value: "DoubleOne")
                LabeledContent("版本", value: "\(Bundle.main.releaseVersionNumber ?? "未知")（\(Bundle.main.buildVersionNumber ?? "未知")）")
                if let githubLink { Link("DoubleOne · GitHub", destination: githubLink) }
                Divider()
                Text("开源致谢").font(.headline)
                Text("基于 Boring Notch（GPL-3.0），保留原项目及依赖的版权与许可。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("boring.notch", destination: URL(string: "https://github.com/TheBoredTeam/boring.notch")!)
                CheckForUpdatesView()
                Text("只检查上游版本，不覆盖定制版。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }
    }
}
