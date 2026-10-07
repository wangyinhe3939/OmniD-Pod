import AppKit
import SwiftUI

@objc(DDOmniRouterFactory) @MainActor
final class OmniRouterFactory: NSObject, DDNativeSlotFactory, NSWindowDelegate {
    private static let shared = OmniRouterFactory()
    private lazy var model = RouterPanelModel()
    private var panel: NSPanel?
    private var openPanel: NSOpenPanel?

    static func makeFactory() -> DDNativeSlotFactory {
        OmniRouterRuntime.shared.start()
        return shared
    }

    func makePanel() -> NSPanel {
        if let panel { return panel }
        let size = OmniDWorkspaceTodaySize.size
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "万有引力"
        window.identifier = NSUserInterfaceItemIdentifier("OmniRouter.Archive")
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        let content = RouterPanel(model: model, pin: { [weak self] in
            guard let self else { return }
            self.model.pinned.toggle()
            self.panel?.level = self.model.pinned ? .floating : .normal
        }, chooseSource: { [weak self] id in self?.choose(.source(id)) }, close: { [weak window] in window?.performClose(nil) })
        window.contentViewController = NSHostingController(rootView: AnyView(content.omniDAccentTheme().workspacePreferences()
            .environment(\.workspaceMaterial, 1).environment(\.colorScheme, .dark)
            .onExitCommand { [weak window] in window?.performClose(nil) }))
        (window.contentView as? NSHostingView<AnyView>)?.sizingOptions = []
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.minSize = window.frame.size
        window.maxSize = window.frame.size
        OmniDWorkspaceWindowStyle.apply(window, material: 1)
        window.delegate = self
        window.center()
        panel = window
        return window
    }

    func makeSettingsController() -> NSViewController {
        NSHostingController(rootView: RouterSettingsView(model: model,
            chooseArchive: { [weak self] in self?.choose(.archive) },
            chooseIndex: { [weak self] in self?.choose(.index) },
            chooseTransfer: { [weak self] in self?.choose(.transfer) })
            .workspacePreferences().font(.system(size: 11)).controlSize(.small))
    }

    func makeAttentionController() -> NSViewController {
        NSHostingController(rootView: RouterTransferAttention(model: model) {
            OffKeyWindowCoordinator.shared.performWorkspaceAction(.router)
        })
    }

    private enum Selection { case archive, index, transfer, source(UUID) }
    private func choose(_ selection: Selection) {
        guard openPanel == nil else { return }
        let chooser = NSOpenPanel()
        let directories: Bool
        switch selection {
        case .archive:
            directories = true
            chooser.title = "图片和文件存到哪里？"
            chooser.prompt = "选这个位置"
            chooser.message = "在 iCloud Drive 或 Google Drive 里选一个位置。App 会在里面创建「万物仓」并按分类保存文件；已有万物仓也可以直接选中。"
            chooser.directoryURL = model.settings?.archive.location
        case .index:
            directories = true
            chooser.title = "选择你的 Obsidian 笔记库"
            chooser.prompt = "选这个笔记库"
            chooser.message = "选择你平时在 Obsidian 打开的笔记库文件夹，也就是能看到已有笔记的那一层。首次归档后，里面会生成「万有引力｜万物总索引.md」。"
            chooser.directoryURL = model.settings?.indexParent.location
        case .source:
            directories = false
            chooser.title = "重新授权这一操作的原文件"
        case .transfer:
            directories = true
            chooser.title = "允许创建 iCloud 手机收件箱"
            chooser.prompt = "允许并创建"
            chooser.message = "选中 iCloud Drive 后点「允许并创建」。App 会自动建好「OmniD-Transfer」、设置本机 App 图标并开启接收；已有同名文件夹会继续使用。"
            chooser.directoryURL = RouterAccess.iCloudDrive
        }
        chooser.canChooseDirectories = directories
        chooser.canChooseFiles = !directories
        chooser.canCreateDirectories = directories
        if case .transfer = selection { chooser.canCreateDirectories = false }
        chooser.allowsMultipleSelection = false
        openPanel = chooser
        model.choosing = true
        let owner = NSApp.keyWindow
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            self.model.choosing = false
            guard response == .OK, let url = chooser.url else { return }
            let apply = {
                switch selection {
                case .archive: self.model.saveSelection(archive: url, index: nil)
                case .index: self.model.saveSelection(archive: nil, index: url)
                case .source(let id): OmniRouterRuntime.shared.authorizeSource(id, file: url)
                case .transfer: self.model.saveTransfer(parent: url)
                }
            }
            let previous: URL?
            let title: String
            switch selection {
            case .archive: previous = self.model.settings?.archive.location; title = "更换文件存放位置？"
            case .index: previous = self.model.settings?.indexParent.location; title = "更换 Obsidian 笔记库？"
            case .transfer: previous = self.model.transferState.location; title = "更换手机收件箱？"
            case .source: apply(); return
            }
            if let previous, previous.standardizedFileURL != url.standardizedFileURL {
                DispatchQueue.main.async {
                    OmniDWorkspaceNotice.confirm(title,
                        message: "新位置：\(RouterAccess.displayLocation(url))\n\n仅后续操作使用新位置，旧文件和旧索引仍保留在原处。",
                        confirmTitle: "确认更换", window: owner, action: apply)
                }
            } else { apply() }
        }
        if let owner { chooser.beginSheetModal(for: owner, completionHandler: completion) }
        else { chooser.begin(completionHandler: completion) }
    }

    func windowWillClose(_ notification: Notification) {
        if let openPanel, openPanel.sheetParent === panel { openPanel.cancel(nil) }
        // The process-owned runtime and model survive window closure.
    }
}
