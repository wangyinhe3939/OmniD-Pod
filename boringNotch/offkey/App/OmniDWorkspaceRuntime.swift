import AppKit
import Combine
import Defaults
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class OmniDWorkspacePreferences: ObservableObject {
    static let shared = OmniDWorkspacePreferences()
    @Published var mode: Int { didSet { defaults.set(mode, forKey: "omnid.workspace.mode"); applyAppearance() } }
    @Published var material: Int { didSet { defaults.set(material, forKey: "omnid.workspace.material"); applyAppearance() } }
    @Published var palette: ONEAccentPalette {
        didSet { Defaults[.oneAccentPaletteID] = palette.rawValue; Defaults[.useCustomAccentColor] = true }
    }
    @Published var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "omnid.workspace.reduceMotion") } }
    @Published var textScale: Double { didSet { defaults.set(textScale, forKey: "omnid.workspace.textScale") } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMode = defaults.object(forKey: "omnid.workspace.mode") as? Int ?? 2
        mode = (0...2).contains(storedMode) ? storedMode : 2
        material = defaults.integer(forKey: "omnid.workspace.material") == 1 ? 1 : 0
        palette = Defaults[.oneAccentPaletteID].flatMap(ONEAccentPalette.featuredCase(resolvingStoredID:)) ?? .electricPurple
        reduceMotion = defaults.bool(forKey: "omnid.workspace.reduceMotion")
        let scale = defaults.double(forKey: "omnid.workspace.textScale")
        textScale = scale.isFinite && (1...1.3).contains(scale) ? scale : 1
    }

    func applyAppearance() {
        NSApp.appearance = mode == 0 ? NSAppearance(named: .aqua) : mode == 1 ? NSAppearance(named: .darkAqua) : nil
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("OmniDWorkspace") == true {
            style(window)
        }
    }

    func style(_ window: NSWindow) {
        OmniDWorkspaceWindowStyle.apply(window, material: material)
    }
}

private struct WorkspacePreferencesModifier: ViewModifier {
    @ObservedObject private var preferences = OmniDWorkspacePreferences.shared
    @Default(.useCustomAccentColor) private var useAccent
    @Default(.oneAccentPaletteID) private var paletteID
    @Default(.customAccentColorData) private var customAccentData
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    func body(content: Content) -> some View {
        let theme = OmniDAccentTheme(useCustom: useAccent, paletteID: paletteID, data: customAccentData)
        // AppKit owns the window appearance; nil follows macOS for both chrome and content.
        content
            .environment(\.workspaceAccentColor, theme.accent)
            .environment(\.workspaceAccentForeground, theme.foreground)
            .environment(\.workspaceTextScale, preferences.textScale)
            .environment(\.workspaceMaterial, preferences.material)
            .environment(\.omniDAccentTheme, theme)
            .tint(theme.accent).accentColor(theme.accent)
            .workspaceTextAccent(theme.accent)
            .transaction {
                if preferences.reduceMotion || systemReduceMotion { $0.animation = nil; $0.disablesAnimations = true }
            }
    }
}

extension View {
    func workspacePreferences() -> some View { modifier(WorkspacePreferencesModifier()) }
}

struct OmniDWorkspaceRoot: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var notes = OffKeyWindowCoordinator.shared.notesStore
    @ObservedObject private var shelf = ShelfStateViewModel.shared
    @ObservedObject private var cleaning = OffKeyCleaningController.shared
    @ObservedObject private var music = MusicManager.shared

    private var pending: [OffKeyNoteRecord] { notes.document.workspaceRecords(isTask: true, showCompleted: false) }
    var body: some View {
        OmniDWorkspaceMenu(logo: NSImage(named: "DDMenuBar"), taskCount: pending.count,
            nextTask: pending.first?.title ?? "", fileCount: shelf.items.count,
            cleaningStatus: cleaning.isCleaning ? "正在清洁" : cleaning.hasPermissions ? "可以开始" : "需要授权",
            mediaTitle: !music.isPlayerIdle && music.songTitle != "未在播放" ? music.songTitle : nil) { action in
                dismiss()
                OffKeyWindowCoordinator.shared.performWorkspaceAction(action)
            }
            .workspacePreferences()
            .onAppear { cleaning.refreshPermissions(); OmniDWorkspacePreferences.shared.applyAppearance() }
    }
}

struct OmniDWorkspaceTodayHost: View {
    @ObservedObject private var reminders = OmniDWorkspaceReminders.shared
    @ObservedObject var notes: OffKeyNotesStore
    @ObservedObject var coordinator: OffKeyWindowCoordinator
    @State private var showProject = false
    @State private var showReminder = false
    @State private var showBatch = false
    @State private var editingID: String?
    @State private var editingText = ""
    @State private var selectedDate = Date().addingTimeInterval(3_600)
    @State private var reminderRecordID: String?
    @State private var now = Date()
    @State private var message: String?

    private var records: [OffKeyNoteRecord] {
        notes.document.workspaceRecords(isTask: coordinator.workspaceTab == 0,
            showCompleted: coordinator.showCompleted, project: coordinator.projectFilter, now: now)
    }
    private var tasks: [OmniDWorkspaceTask] {
        records.map { record in
            var detail = record.workspace?.project ?? ""
            if let date = record.workspace?.scheduledDate {
                detail += (detail.isEmpty ? "" : " · ") + date.formatted(.dateTime.month().day())
                if date < Calendar.current.startOfDay(for: now), record.workspace?.completed != true {
                    detail += " · 未完成"
                }
            } else if record.workspace?.isTask == true {
                detail += (detail.isEmpty ? "" : " · ") + "未安排日期"
            }
            if record.workspace?.reminderDate != nil { detail += " · 有提醒" }
            return OmniDWorkspaceTask(id: record.id, title: record.title.isEmpty ? String(record.notes.prefix(80)) : record.title,
                detail: detail.isEmpty ? "保留原文" : detail, completed: record.workspace?.completed ?? false)
        }
    }

    var body: some View {
        OmniDWorkspaceToday(draft: Binding(get: { notes.workspaceDraft.text }, set: { notes.updateWorkspaceDraft(text: $0) }),
            tab: $coordinator.workspaceTab, dateLabel: now.formatted(.dateTime.month().day().weekday()),
            tasks: tasks, persistenceStatus: message ?? (notes.hasUnsavedChanges ? notes.statusMessage : reminders.status + (notes.statusMessage.isEmpty ? "" : " · " + notes.statusMessage)),
            projectLabel: notes.workspaceDraft.project.isEmpty ? "项目" : notes.workspaceDraft.project,
            reminderLabel: notes.workspaceDraft.reminderDate?.formatted(.dateTime.hour().minute()) ?? "提醒",
            pinned: coordinator.todayPinned, showingCompleted: coordinator.showCompleted,
            onBatchSave: { showBatch = true }, onRecordAction: recordAction,
            onAction: action, onToggle: { id in
                if reminders.update(id: id, notes: notes, edit: { record in
                    var metadata = record.workspace ?? OffKeyWorkspaceMetadata(isTask: false)
                    if metadata.isTask { metadata.completed.toggle() }
                    else { metadata.isTask = true; metadata.scheduledDate = Date(); metadata.completed = false }
                    record.workspace = metadata
                }) { message = nil }
            })
            .workspacePreferences()
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = Date() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = Date() }
            .popover(isPresented: $showProject) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("项目可不填").font(.headline)
                    TextField("项目名称", text: Binding(get: { notes.workspaceDraft.project }, set: { notes.updateWorkspaceDraft(project: $0) }))
                    OmniDWorkspaceChoicePicker(title: "显示项目", selection: $coordinator.projectFilter,
                        choices: [("全部", "")] + Array(Set(notes.document.entries.compactMap { $0.workspace?.project }
                            .filter { !$0.isEmpty })).sorted().map { ($0, $0) })
                    Button("完成") { showProject = false }.keyboardShortcut(.defaultAction)
                }.font(.system(size: 11)).controlSize(.small)
                    .buttonStyle(OmniDWorkspaceButtonStyle()).padding(12).frame(width: 220)
                    .workspacePreferences().workspaceSecondarySurface()
            }
            .popover(isPresented: $showReminder) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("这条待办的提醒").font(.headline)
                    DatePicker("时间", selection: $selectedDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Text("保存待办后再安排；通知权限未允许时会明确提示。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("不提醒") { setReminder(nil) }
                        Spacer()
                        Button("设定") { setReminder(selectedDate) }
                    }
                }.font(.system(size: 11)).controlSize(.small)
                    .buttonStyle(OmniDWorkspaceButtonStyle()).padding(12).frame(width: 250)
                    .workspacePreferences().workspaceSecondarySurface()
            }
            .sheet(isPresented: $showBatch) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("每行一条，确认后加入").font(.headline)
                    ScrollView { Text(notes.workspaceDraft.text).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        Button("取消") { showBatch = false }
                        Spacer()
                        Button("加入") { if save(separateLines: true) { showBatch = false } }
                    }
                }.padding(20).frame(width: 300, height: 280).workspacePreferences().workspaceSecondarySurface()
            }
            .sheet(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("编辑原文").font(.headline)
                    TextEditor(text: $editingText)
                    HStack {
                        Button("取消") { editingID = nil }
                        Spacer()
                        Button("保存") {
                            if let id = editingID, reminders.update(id: id, notes: notes, edit: {
                                $0.notes = editingText
                                $0.title = String((editingText.components(separatedBy: .newlines).first ?? editingText).prefix(OffKeyNotesDocument.maxTitleCount))
                            }) { editingID = nil }
                        }
                        .disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editingText.count > OffKeyNotesDocument.maxNotesCount)
                    }
                }.padding(20).frame(width: 300, height: 300).workspacePreferences().workspaceSecondarySurface()
            }
            .workspaceNotice("需要处理", isPresented: Binding(get: { notes.presentedError != nil || reminders.error != nil },
                set: { if !$0 { notes.presentedError = nil; reminders.error = nil } }),
                message: notes.presentedError ?? reminders.error ?? "")
    }

    private func action(_ action: OmniDWorkspaceAction) {
        switch action {
        case .save: save(separateLines: false)
        case .project: showProject = true
        case .reminder: reminderRecordID = nil; selectedDate = notes.workspaceDraft.reminderDate ?? Date().addingTimeInterval(3_600); showReminder = true
        case .pin: coordinator.toggleTodayPin()
        case .showCompleted: coordinator.showCompleted.toggle()
        case .dictate:
            DispatchQueue.main.async {
                if !NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) {
                    message = "输入框已聚焦；请用 Mac 的听写快捷键。可在系统设置 → 键盘 → 听写中检查。"
                }
            }
        default: coordinator.performWorkspaceAction(action)
        }
    }

    @discardableResult
    private func save(separateLines: Bool) -> Bool {
        guard notes.saveWorkspaceCapture(isTask: coordinator.workspaceTab == 0, separateLines: separateLines) else { return false }
        message = nil
        // Reminder delivery is handled separately from successful local persistence.
        Task {
            if let calendarID = reminders.selectedCalendarID {
                await reminders.migrate(to: calendarID, notes: notes)
            } else {
                if notes.document.entries.contains(where: { $0.workspace?.reminderDate != nil && $0.workspace?.reminderIdentifier == nil }) {
                    await reminders.requestNotifications()
                }
                reminders.reconcile(notes: notes)
            }
        }
        return true
    }

    private func setReminder(_ date: Date?) {
        if let id = reminderRecordID {
            guard reminders.update(id: id, notes: notes, edit: { $0.workspace?.reminderDate = date }) else { return }
            if date != nil, notes.document.entries.first(where: { $0.id == id })?.workspace?.reminderIdentifier == nil {
                Task { await reminders.requestNotifications() }
            }
        } else {
            notes.updateWorkspaceDraft(reminderDate: date, changesReminder: true)
        }
        showReminder = false
    }

    private func recordAction(_ id: String, _ action: String) {
        guard let record = notes.document.entries.first(where: { $0.id == id }) else { return }
        switch action {
        case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.workspaceText, forType: .string)
        case "edit": editingText = record.workspaceText; editingID = id
        case "reminder":
            reminderRecordID = id
            selectedDate = max(record.workspace?.reminderDate ?? Date().addingTimeInterval(3_600), Date())
            showReminder = true
        case "tomorrow": _ = reminders.update(id: id, notes: notes) {
            guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return }
            $0.workspace?.scheduledDate = tomorrow
            if let previous = $0.workspace?.reminderDate {
                let time = Calendar.current.dateComponents([.hour, .minute], from: previous)
                $0.workspace?.reminderDate = Calendar.current.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: tomorrow)
            }
        }
        case "undated": _ = reminders.update(id: id, notes: notes) { $0.workspace?.scheduledDate = nil; $0.workspace?.reminderDate = nil }
        default: break
        }
    }
}

struct OmniDWorkspaceAppearanceHost: View {
    @ObservedObject private var preferences = OmniDWorkspacePreferences.shared
    @Default(.useCustomAccentColor) private var useAccent
    @Default(.oneAccentPaletteID) private var paletteID
    @Default(.customAccentColorData) private var customAccentData
    @AppStorage(OmniDPodAppIcon.preferenceKey) private var selectedIcon = OmniDPodAppIconVariant.smile.rawValue
    @State private var colorError: String?
    var onBack: (() -> Void)?
    let onClose: () -> Void
    var body: some View {
        OmniDWorkspaceAppearance(mode: $preferences.mode, palette: $preferences.palette,
            reduceMotion: $preferences.reduceMotion, textScale: $preferences.textScale,
            material: $preferences.material,
            usingPalette: useAccent && paletteID != nil,
            customAccent: Binding(get: { Color.effectiveAccent }, set: { color in
                do {
                    customAccentData = try NSKeyedArchiver.archivedData(withRootObject: NSColor(color), requiringSecureCoding: false)
                    paletteID = nil
                    useAccent = true
                } catch { colorError = error.localizedDescription }
            }), onResetAccent: { useAccent = false },
            icons: OmniDPodAppIconVariant.allCases.map {
                OmniDWorkspaceIcon(id: $0.rawValue, title: $0.title, image: $0.image)
            }, selectedIcon: (OmniDPodAppIconVariant(rawValue: selectedIcon) ?? .smile).rawValue, onIconSelect: { id in
                guard let variant = OmniDPodAppIconVariant(rawValue: id) else { return }
                selectedIcon = id
                OmniDPodAppIcon.apply(variant)
            }, onBack: onBack, onClose: onClose)
            .workspacePreferences()
            .workspaceNotice("颜色未保存", isPresented: Binding(get: { colorError != nil }, set: { if !$0 { colorError = nil } }),
                message: colorError ?? "")
    }
}

struct OmniDWorkspaceShelfHost: View {
    @ObservedObject var coordinator: OffKeyWindowCoordinator
    @ObservedObject private var shelf = ShelfStateViewModel.shared
    @State private var expanded = false
    @StateObject private var quickLook = QuickLookService()
    @State private var failure: String?
    @State private var previewText: String?

    private var files: [OmniDWorkspaceFile] {
        shelf.items.map { item in
            switch item.kind {
            case .file:
                let url = shelf.resolveFileURL(for: item)
                let available = url?.accessSecurityScopedResource { FileManager.default.fileExists(atPath: $0.path) } ?? false
                return OmniDWorkspaceFile(id: item.id.uuidString, name: url?.lastPathComponent ?? "失效引用",
                    detail: available ? "原文件引用" : "不可用，请重新选择", symbol: available ? "doc" : "exclamationmark.triangle")
            case .text(let text):
                return OmniDWorkspaceFile(id: item.id.uuidString, name: String(text.prefix(80)), detail: "暂存文字", symbol: "text.alignleft")
            case .link(let url):
                return OmniDWorkspaceFile(id: item.id.uuidString, name: url.host ?? url.absoluteString, detail: "链接", symbol: "link")
            }
        }
    }
    var body: some View {
        OmniDWorkspaceShelf(files: files, expanded: expanded, pinned: coordinator.shelfPinned,
            onFileAction: fileAction, fileProvider: provider,
            drop: { providers in
                guard shelf.canModifyItems else { return false }
                let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                guard !fileProviders.isEmpty else { return false }
                shelf.load(fileProviders); return true
            }, status: failure ?? shelf.persistenceIssue?.message) { action in
                switch action {
                case .expandShelf: expanded = true
                case .collapseShelf: expanded = false
                case .chooseFiles: chooseFiles()
                case .share: share()
                case .pin: coordinator.toggleShelfPin()
                default: coordinator.performWorkspaceAction(action)
                }
            }
            .workspacePreferences()
            .quickLookPresenter(using: quickLook)
            .onAppear { resizeShelf() }
            .onChange(of: expanded) { _, _ in resizeShelf() }
            .onChange(of: shelf.items.count) { _, _ in resizeShelf() }
            .onDisappear { quickLook.hide() }
            .popover(isPresented: Binding(get: { previewText != nil }, set: { if !$0 { previewText = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("暂存文字").font(.headline)
                    ScrollView { Text(previewText ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("复制原文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(previewText ?? "", forType: .string)
                    }
                }.padding(16).frame(width: 300, height: 220).workspacePreferences().workspaceSecondarySurface()
            }
    }

    private func resizeShelf() {
        coordinator.resizeShelf(expanded: expanded, count: shelf.items.count,
                                animated: !OmniDWorkspacePreferences.shared.reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func chooseFiles() {
        guard shelf.canModifyItems else { failure = "现有暂存数据不可读，未加入文件。"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            do {
                let items = try panel.urls.map { ShelfItem(kind: .file(bookmark: try Bookmark(url: $0).data)) }
                shelf.add(items)
            } catch { failure = error.localizedDescription }
        }
    }

    private func fileAction(_ id: String, _ action: String) {
        guard let item = shelf.items.first(where: { $0.id.uuidString == id }) else { return }
        if action == "remove" {
            OmniDWorkspaceNotice.confirm("移除这条暂存引用？", message: "这里只移除暂存列表中的条目，原文件会保留。", confirmTitle: "移除引用") { shelf.remove(item) }
            return
        }
        if action == "reveal" {
            guard case .file = item.kind else { failure = "这条内容不是文件，没有 Finder 位置。"; return }
            ShelfActionService.reveal(item); return
        }
        if case .text(let text) = item.kind { previewText = text; return }
        guard let url = item.fileURL ?? item.URL,
              !url.isFileURL || url.accessSecurityScopedResource(accessor: { FileManager.default.fileExists(atPath: $0.path) }) else {
            failure = "原文件不可用；暂存引用保留，可移除或重新选择。"; return
        }
        quickLook.show(urls: [url])
    }

    private func provider(_ id: String) -> NSItemProvider {
        guard let item = shelf.items.first(where: { $0.id.uuidString == id }) else { return NSItemProvider() }
        if case .text(let text) = item.kind { return NSItemProvider(object: text as NSString) }
        guard let url = item.fileURL ?? item.URL else { return NSItemProvider() }
        // Export the URL, not a file-content representation or an extra copy.
        return NSItemProvider(object: url as NSURL)
    }

    private func share() {
        var items: [Any] = []
        for item in shelf.items {
            switch item.kind {
            case .text(let text): items.append(text)
            case .link(let url): items.append(url)
            case .file:
                guard let url = shelf.resolveAndUpdateBookmark(for: item),
                      url.accessSecurityScopedResource(accessor: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    failure = "存在不可用引用，未发起分享。"; return
                }
                items.append(url)
            }
        }
        guard !items.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        Task {
            await QuickShareService.shared.shareFilesOrText(items,
                using: QuickShareProvider(id: "系统分享菜单", imageData: nil, supportsRawText: true), from: view)
        }
    }
}

struct OmniDWorkspaceSearchHost: View {
    @State private var query = ""
    @FocusState private var focused: Bool
    let coordinator: OffKeyWindowCoordinator
    private var actions: [(String, OmniDWorkspaceAction)] { [
        ("今日 清单 待办", .today), ("随手记 灵感 文字 听写", .capture),
        ("暂存文件 文件托盘 分享", .shelf), ("键盘清洁 锁定键盘", .cleaning), ("设置 外观", .settings)
    ] + (DDOptionalNativeSlot.shared.factory == nil ? [] : [("万有引力 归档", .router)]) }
    private var matching: [(String, OmniDWorkspaceAction)] {
        actions.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("搜索应用内动作", text: $query).focused($focused)
                .onSubmit { if let first = matching.first { coordinator.performWorkspaceAction(first.1) } }
            ForEach(Array(matching.enumerated()), id: \.offset) { _, value in
                Button(value.0.components(separatedBy: " ").first ?? value.0) { coordinator.performWorkspaceAction(value.1) }
                    .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            }
            if matching.isEmpty { Text("没有匹配的动作").foregroundStyle(.secondary) }
            Text("只搜索本应用的动作，不扫描你的文件。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 330).workspacePreferences().onAppear { focused = true }
    }
}
