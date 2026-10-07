import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
final class OffKeyWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = OffKeyWindowCoordinator()

    let notesStore = OffKeyNotesStore()
    let namingStore = OffKeyNamingStore()
    private var cleaningWindow: NSWindow?
    private var notesWindow: NSWindow?
    private var namingWindow: NSWindow?
    private var shelfWindow: NSWindow?
    private var searchWindow: NSWindow?
    private var routerWindow: NSPanel?
    @Published var workspaceTab = 0
    @Published var showCompleted = false
    @Published var projectFilter = ""
    @Published var todayPinned = false
    @Published var shelfPinned = false

    private override init() {
        super.init()
        for (shortcut, action) in [
            (KeyboardShortcuts.Name.workspaceToday, OmniDWorkspaceAction.today),
            (.workspaceCapture, .capture), (.workspaceShelf, .shelf),
            (.workspaceArchive, .router), (.workspaceCleaning, .cleaning)
        ] {
            KeyboardShortcuts.onKeyDown(for: shortcut) { [weak self] in
                Task { @MainActor in self?.performWorkspaceAction(action) }
            }
        }
    }

    func showLauncher() {
        // Dock reopen goes straight to a useful tool; the menu stays in the menu bar.
        showToday()
    }

    func showCleaning() {
        if cleaningWindow == nil {
            cleaningWindow = makeWindow(
                title: OffKeyL10n.text("offkey.menu.cleaning", fallback: "键盘清洁"),
                content: AnyView(OffKeyCleaningView(controller: .shared)),
                size: NSSize(width: 360, height: 238)
            )
        }
        present(cleaningWindow)
    }

    func showNotes() {
        showToday(capture: true)
    }

    func showToday(capture: Bool = false) {
        guard !OffKeyCleaningController.shared.isCleaning else {
            showCleaning()
            return
        }
        if notesWindow == nil {
            notesWindow = makeWindow(
                title: "今日与灵感",
                content: AnyView(OmniDWorkspaceTodayHost(notes: notesStore, coordinator: self)),
                size: OmniDWorkspaceTodaySize.size
            )
            notesWindow?.styleMask.remove(.resizable)
            notesWindow?.contentMinSize = OmniDWorkspaceTodaySize.size
            notesWindow?.contentMaxSize = OmniDWorkspaceTodaySize.size
        }
        workspaceTab = capture ? 1 : 0
        present(notesWindow)
    }

    func showShelf() {
        guard !OffKeyCleaningController.shared.isCleaning else { showCleaning(); return }
        if shelfWindow == nil {
            shelfWindow = makeWindow(title: "暂存文件", content: AnyView(OmniDWorkspaceShelfHost(coordinator: self)),
                                     size: NSSize(width: 280, height: 144))
            shelfWindow?.styleMask.remove(.resizable)
            resizeShelf(expanded: false, count: ShelfStateViewModel.shared.items.count, animated: false)
        }
        present(shelfWindow)
    }

    func showAppearance() {
        SettingsWindowController.shared.showAppearanceSettings()
    }

    func performWorkspaceAction(_ action: OmniDWorkspaceAction) {
        switch action {
        case .today: showToday()
        case .capture: showToday(capture: true)
        case .shelf: showShelf()
        case .router:
            guard !OffKeyCleaningController.shared.isCleaning else { showCleaning(); return }
            if routerWindow == nil { routerWindow = DDOptionalNativeSlot.shared.factory?.makePanel() }
            present(routerWindow)
        case .cleaning: showCleaning()
        case .settings: SettingsWindowController.shared.showWindow()
        case .quit: NSApp.terminate(nil)
        case .media: BoringViewCoordinator.shared.showNotch(.home)
        case .search:
            if searchWindow == nil {
                searchWindow = makeWindow(title: "动作搜索", content: AnyView(OmniDWorkspaceSearchHost(coordinator: self)),
                                          size: NSSize(width: 330, height: 270))
            }
            present(searchWindow)
        default: break
        }
    }

    func toggleTodayPin() {
        todayPinned.toggle()
        notesWindow?.level = todayPinned ? .floating : .normal
    }

    func toggleShelfPin() {
        shelfPinned.toggle()
        shelfWindow?.level = shelfPinned ? .floating : .normal
    }

    func resizeShelf(expanded: Bool, count: Int, animated: Bool) {
        guard let window = shelfWindow else { return }
        let size = count == 0 ? NSSize(width: 280, height: 144)
            : expanded ? NSSize(width: 330, height: 370) : NSSize(width: 280, height: 330)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animated)
    }

    func showNaming() {
        guard !OffKeyCleaningController.shared.isCleaning else {
            showCleaning()
            return
        }
        if namingWindow == nil {
            namingWindow = makeWindow(
                title: "快速命名",
                content: AnyView(OffKeyNamingView(store: namingStore)),
                size: NSSize(width: 560, height: 420)
            )
        }
        present(namingWindow)
    }

    func prepareForSettings() {
        hideUnpinned(except: nil)
        BoringViewCoordinator.shared.prepareForToolWindow()
    }

    @discardableResult
    func hideToolWindowsForCleaning() -> Bool {
        guard notesStore.saveImmediately() else {
            showNotes()
            return false
        }
        notesWindow?.orderOut(nil)
        namingWindow?.orderOut(nil)
        shelfWindow?.orderOut(nil)
        searchWindow?.orderOut(nil)
        routerWindow?.orderOut(nil)
        return true
    }

    @discardableResult
    func prepareForTermination() -> Bool {
        guard notesStore.saveImmediately() else { return false }
        OffKeyCleaningController.shared.prepareForTermination()
        return true
    }

    private func makeWindow(title: String, content: AnyView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier("OmniDWorkspace.\(title)")
        window.appearance = nil
        window.contentViewController = NSHostingController(
            rootView: AnyView(content.omniDAccentTheme().workspacePreferences()
                .onExitCommand { [weak window] in window?.performClose(nil) })
        )
        (window.contentView as? NSHostingView<AnyView>)?.sizingOptions = []
        OmniDWorkspacePreferences.shared.style(window)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        hideUnpinned(except: window)
        BoringViewCoordinator.shared.prepareForToolWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func hideUnpinned(except selected: NSWindow?) {
        for window in [notesWindow, shelfWindow, searchWindow, namingWindow, routerWindow] {
            guard let window, window !== selected else { continue }
            if (todayPinned && window === notesWindow) || (shelfPinned && window === shelfWindow) { continue }
            if window === routerWindow && window.level == .floating { continue }
            window.orderOut(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === cleaningWindow { OffKeyCleaningController.shared.stopCleaning() }
        return sender !== notesWindow || notesStore.saveImmediately()
    }
}
