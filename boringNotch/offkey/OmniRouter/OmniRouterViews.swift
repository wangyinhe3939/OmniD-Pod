import AppKit
import Combine
import SwiftUI

@MainActor final class RouterPanelModel: ObservableObject {
    @Published var draft = ""
    @Published var inputs = [RouterInput]()
    @Published var category: RouterCategory = .notes
    @Published var receipts = [UUID: RouterReceipt]()
    @Published var settings: RouterSettings?
    @Published var message = "本地归档与索引成功后才清理源文件；云端同步未确认。"
    @Published var settingsMessage = ""
    @Published var choosing = false
    @Published var pinned = false
    @Published var aiEnabled = false
    @Published var aiKeyAvailable = false
    @Published var aiKeyDraft = ""
    @Published var aiSettingsMessage = ""
    @Published var savingAI = false
    @Published var transferState = RouterTransferState()
    @Published var transferEnabled = false
    @Published var transferMessage = ""
    @Published var savingTransfer = false
    @Published var receivingTransfer = false
    var selectedArchive: URL?
    var selectedIndex: URL?
    private var subscription: AnyCancellable?
    private var transferSubscription: AnyCancellable?
    private var transferLoaded = false
    private var shortcutSharing: SharingLifecycleDelegate?

    var history: [RouterReceipt] {
        receipts.values.filter { $0.phase != .undone && $0.title != nil }.sorted {
            let first = $0.created ?? .distantPast, second = $1.created ?? .distantPast
            return first == second ? $0.operationID.uuidString > $1.operationID.uuidString : first > second
        }
    }

    init() {
        let runtime = OmniRouterRuntime.shared
        transferState = runtime.transfer.snapshot()
        transferEnabled = transferState.enabled
        transferSubscription = runtime.transfer.updates.sink { [weak self] state in
            guard let self else { return }
            self.transferState = state
            if !self.transferLoaded || !state.enabled { self.transferEnabled = state.enabled; self.transferLoaded = true }
        }
        for receipt in runtime.snapshot() { receipts[receipt.operationID] = receipt }
        subscription = runtime.receipts.sink { [weak self] receipt in
            self?.receipts[receipt.operationID] = receipt
            if [.fileCommitted, .indexCommitted, .complete, .undone].contains(receipt.phase) {
                self?.inputs.removeAll { $0.id == receipt.operationID }
            }
            self?.message = receipt.message
        }
        runtime.settings { [weak self] result in
            switch result {
            case .success(let settings):
                self?.settings = settings
                if settings == nil { self?.message = "先到「设置 → 权限与数据 → 万有引力 → 归档」，选好文件存放位置和 Obsidian 笔记库。" }
            case .failure(let error):
                self?.settings = nil
                self?.settingsMessage = "未授权：目录配置或恢复日志不可用，请重新选择目录并检查本地日志。" + RouterFailure.message(for: error)
                self?.message = self?.settingsMessage ?? "未授权"
            }
        }
        runtime.start()
        runtime.aiSettings { [weak self] result in
            self?.applyAISettings(result)
        }
    }

    func submit(intelligent: Bool = false) {
        guard let settings else { message = "请先在「设置 → 权限与数据 → 万有引力 → 归档」选好文件存放位置和 Obsidian 笔记库。"; return }
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value: RouterInputValue
            if let url = URL(string: draft), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { value = .web(draft) }
            else { value = .text(draft) }
            inputs.append(RouterInput(value: value, title: String(draft.prefix(160))))
            draft = ""
        }
        for input in inputs { OmniRouterRuntime.shared.accept(input, category: category, settings: settings, intelligent: intelligent) }
    }

    func saveAI(removeKey: Bool = false) {
        guard !savingAI else { return }
        savingAI = true
        let key = aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        aiKeyDraft = ""
        OmniRouterRuntime.shared.configureAI(enabled: !removeKey && aiEnabled, key: key, removeKey: removeKey) { [weak self] result in
            self?.savingAI = false
            self?.applyAISettings(result)
            if case .success = result { self?.aiSettingsMessage = removeKey ? "智能识别已停用，密钥已移除。" : "设置已保存；只有点击智能处理才会发送资料。" }
        }
    }

    func saveTransfer(parent: URL? = nil, unbind: Bool = false) {
        guard !savingTransfer else { return }
        savingTransfer = true
        let icon = parent == nil ? nil : Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        OmniRouterRuntime.shared.transfer.configure(parent: parent, enabled: parent != nil || transferEnabled, unbind: unbind,
            cloudRoot: parent == nil ? nil : RouterAccess.iCloudDrive, iconURL: icon) { [weak self] result in
            guard let self else { return }
            self.savingTransfer = false
            switch result {
            case .success(let settings):
                self.transferEnabled = settings.enabled
                if unbind { self.transferMessage = "已断开手机收件箱，里面的文件仍保留。" }
                else if parent != nil {
                    self.transferMessage = "手机收件箱已准备好并开启接收。下一步添加下方两份快捷指令。"
                    if settings.folderIconApplied != true { self.transferMessage += "系统未能设置文件夹图标，接收仍可使用。" }
                } else { self.transferMessage = settings.enabled ? "已开启手机分享接收。" : "已暂停接收，手机分享的文件会留在收件箱。" }
            case .failure(let error): self.transferEnabled = false; self.transferMessage = RouterFailure.message(for: error)
            }
        }
    }

    func addShortcut(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "shortcut"), NSWorkspace.shared.open(url) else {
            transferMessage = "无法打开添加窗口，请检查「快捷指令」App 和当前安装包。"
            return
        }
        transferMessage = "已打开「快捷指令」。请在系统窗口点「添加快捷指令」；添加后可通过 iCloud 同步到手机和平板。"
    }

    func shareShortcut(_ name: String) {
        guard shortcutSharing == nil else { transferMessage = "请先完成或取消当前隔空投送。"; return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "shortcut"),
              let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            transferMessage = "当前无法隔空投送。可以先添加到 Mac 的「快捷指令」，再开启快捷指令的 iCloud 同步。"
            return
        }
        let delegate = SharingLifecycleDelegate(id: UUID(), onEnd: { [weak self] in self?.shortcutSharing = nil },
                                                onBegin: {}, onFinish: {})
        shortcutSharing = delegate
        delegate.retain(service: service)
        delegate.markServiceBegan()
        service.delegate = delegate
        service.perform(withItems: [url])
        transferMessage = "在隔空投送窗口选择你的 iPhone 或 iPad；设备接收后点「添加快捷指令」。"
    }

    func receiveTransfer() {
        guard !receivingTransfer else { return }
        receivingTransfer = true
        OmniRouterRuntime.shared.transfer.receive { [weak self] result in
            guard let self else { return }
            self.receivingTransfer = false
            switch result {
            case .success(let values):
                for input in values where !self.inputs.contains(where: { $0.id == input.id }) { self.inputs.append(input) }
                self.message = "已接收中转原文件；请选择分类，再点击记录 / 归档。"
            case .failure(let error): self.message = RouterFailure.message(for: error)
            }
        }
    }

    private func applyAISettings(_ result: Result<(RouterAISettings, Bool), Error>) {
        switch result {
        case .success(let (settings, available)):
            aiEnabled = settings.enabled && available
            aiKeyAvailable = available
        case .failure(let error):
            aiEnabled = false; aiKeyAvailable = false
            aiSettingsMessage = RouterFailure.message(for: error)
        }
    }

    func saveSelection(archive: URL?, index: URL?) {
        if let archive { selectedArchive = archive }
        if let index { selectedIndex = index }
        guard (selectedArchive != nil || settings != nil), (selectedIndex != nil || settings != nil) else {
            settingsMessage = selectedArchive == nil ? "已选好 Obsidian 笔记库；再选择上方存放图片和文件的位置。"
                : "已选好文件存放位置；再选择下方的 Obsidian 笔记库。"
            return
        }
        choosing = true
        OmniRouterRuntime.shared.configure(archive: selectedArchive, indexParent: selectedIndex, current: settings) { [weak self] result in
            self?.choosing = false
            switch result {
            case .success(let settings):
                self?.settings = settings
                self?.selectedArchive = nil; self?.selectedIndex = nil
                self?.settingsMessage = "两处位置已保存。第一次归档时，Obsidian 笔记库里会出现「万有引力｜万物总索引.md」。"
                self?.message = "可以记录文字、网址或拖入普通文件。"
            case .failure(let error):
                self?.settings = nil
                self?.settingsMessage = "未授权：" + RouterFailure.message(for: error)
                self?.message = self?.settingsMessage ?? "未授权"
            }
        }
    }
}

struct RouterCategoryPicker: View {
    @Binding var selection: RouterCategory
    var body: some View {
        HStack(spacing: 4) {
            ForEach(RouterCategory.allCases) { category in
                Button { selection = category } label: {
                    Text(category.rawValue).font(.system(size: 10)).lineLimit(1)
                        .minimumScaleFactor(0.85).frame(maxWidth: .infinity)
                }
                .buttonStyle(OmniDWorkspaceButtonStyle(selected: selection == category)).clipShape(Capsule())
                .accessibilityAddTraits(selection == category ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("归档分类")
    }
}

struct RouterPanel: View {
    @Environment(\.workspaceTextScale) private var scale
    @ObservedObject var model: RouterPanelModel
    let pin: () -> Void
    let chooseSource: (UUID) -> Void
    let close: () -> Void
    @State private var editing: RouterReceipt?

    var body: some View {
        OmniDWorkspaceSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("万有引力").font(.system(size: 17 * scale, weight: .medium))
                        Text("万物索引与归档").font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    OmniDWorkspacePin(pinned: model.pinned, action: pin)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(RouterPrompt.allCases, id: \.self) { prompt in
                            Button(prompt.rawValue) {
                                NSPasteboard.general.clearContents()
                                if NSPasteboard.general.setString(prompt.text, forType: .string) {
                                    model.message = "已复制「" + prompt.rawValue + "」指令。"
                                } else { model.message = "剪贴板写入失败，请重试。" }
                            }.buttonStyle(OmniDWorkspaceButtonStyle()).clipShape(Capsule())
                                .accessibilityLabel("复制" + prompt.rawValue + "指令")
                        }
                    }.frame(height: 24)
                    VStack(spacing: 0) {
                        RouterInputEditor(text: $model.draft, receive: { model.inputs.append(contentsOf: $0) },
                            failure: { model.message = $0 }).frame(height: model.inputs.isEmpty ? 76 : 48)
                            .overlay(alignment: .topLeading) {
                                if model.draft.isEmpty {
                                    Text("写一句，粘贴网址，或拖入文件…").font(.system(size: 12 * scale)).foregroundStyle(.secondary)
                                        .padding(.top, 8).allowsHitTesting(false)
                                }
                            }
                        if !model.inputs.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(model.inputs) { input in
                                        HStack(alignment: .top) {
                                            Image(systemName: "doc")
                                            Text(input.title).fixedSize(horizontal: false, vertical: true).help(input.title)
                                            Spacer(minLength: 0)
                                            if model.receipts[input.id] == nil {
                                                Button { model.inputs.removeAll { $0.id == input.id } } label: { Image(systemName: "xmark") }
                                                    .buttonStyle(.plain).accessibilityLabel("取消接收 " + input.title)
                                            }
                                        }.font(.system(size: 11))
                                    }
                                }
                            }.frame(height: 28)
                        }
                    }.frame(height: 76)
                    RouterCategoryPicker(selection: $model.category)
                    HStack {
                        if model.transferState.items.isEmpty {
                            Text("只归档，不执行").font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Button("接收中转 \(model.transferState.items.count)") { model.receiveTransfer() }
                                .font(.system(size: 10)).buttonStyle(.plain)
                                .disabled(model.receivingTransfer).help(model.transferState.message)
                        }
                        Spacer()
                        Button("智能处理") { model.submit(intelligent: true) }
                            .buttonStyle(OmniDWorkspaceButtonStyle())
                            .help("主动将网址或图片预览发送给智能服务；超过 3 秒回退普通归档。")
                            .disabled(!model.aiEnabled || !model.aiKeyAvailable || model.settings == nil ||
                                (model.inputs.isEmpty && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        Button("记录 / 归档") { model.submit() }
                            .buttonStyle(OmniDWorkspaceButtonStyle(prominent: true))
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(model.settings == nil || (model.inputs.isEmpty && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }.padding(15).modifier(OmniDWorkspaceWell())
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("最近归档").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(model.history.count) 条").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    RouterHistoryScroll(content: AnyView(
                        VStack(alignment: .leading, spacing: 0) {
                            if model.history.isEmpty {
                                Text("记录或归档后，资产会出现在这里。").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            ForEach(model.history, id: \.operationID) { receipt in
                                historyRow(receipt)
                                Divider().opacity(0.45)
                            }
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    )).frame(height: 96)
                }
                Text(model.message).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(2).help(model.message).frame(height: 24, alignment: .topLeading)
            }.padding(18).frame(width: OmniDWorkspaceTodaySize.size.width,
                               height: OmniDWorkspaceTodaySize.size.height, alignment: .topLeading)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let receipt = editing {
                RouterEditView(receipt: receipt, cancel: { editing = nil }, save: { title, category in
                    OmniRouterRuntime.shared.edit(receipt.operationID, title: title, category: category)
                    editing = nil
                }).workspacePreferences().workspaceSecondarySurface()
            }
        }
    }

    private func historyRow(_ receipt: RouterReceipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(receipt.title ?? "资产").font(.system(size: 12)).lineLimit(2)
                Spacer(minLength: 4)
                if let date = receipt.created { Text(date, format: .dateTime.month().day().hour().minute()).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            HStack {
                Text(receipt.category?.rawValue ?? "").font(.system(size: 10))
                Spacer()
                Text(receipt.phase.label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if ![.complete, .queued, .staging].contains(receipt.phase) {
                Text(receipt.message).font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10).contentShape(Rectangle())
        .onTapGesture(count: 2) { if receipt.canEdit { editing = receipt } }
        .contextMenu {
            Button("修改名称与分类…") { editing = receipt }.disabled(!receipt.canEdit)
            Button("在访达中显示") {
                if let url = receipt.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }.disabled(!receipt.canEdit)
            Button("复制笔记链接") {
                if let link = receipt.obsidianLink { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }
            }.disabled(!receipt.canEdit)
            Divider()
            Button("撤销并移入废纸篓", role: .destructive) {
                OmniDWorkspaceNotice.confirm("撤销这条归档？", message: "「\(receipt.title ?? "资产")」的归档文件将移入系统废纸篓，并从总索引中移除。此操作不会把文件搬回原位置。", confirmTitle: "撤销归档") {
                    OmniRouterRuntime.shared.undo(receipt.operationID)
                }
            }.disabled(!receipt.canEdit)
            if [.indexPending, .sourceRetained, .accessRequired, .failed, .editing, .undoPending].contains(receipt.phase) {
                Button("重试同一操作") { OmniRouterRuntime.shared.retry(receipt.operationID, settings: model.settings) }
            }
            if [.sourceRetained, .accessRequired].contains(receipt.phase) {
                Button("重新授权原文件…") { chooseSource(receipt.operationID) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "修改名称与分类") { if receipt.canEdit { editing = receipt } }
    }
}

private struct RouterHistoryScroll: NSViewRepresentable {
    let content: AnyView
    private var rootView: AnyView {
        AnyView(content.frame(width: OmniDWorkspaceTodaySize.size.width - 36, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true).omniDAccentTheme().workspacePreferences()
            .environment(\.workspaceMaterial, 1).environment(\.colorScheme, .dark))
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.setAccessibilityLabel("最近归档列表")
        let document = NSHostingView(rootView: rootView)
        document.sizingOptions = [.intrinsicContentSize]
        document.autoresizingMask = [.width]
        scroll.documentView = document
        document.setFrameSize(document.fittingSize)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? NSHostingView<AnyView> else { return }
        document.rootView = rootView
        document.setFrameSize(document.fittingSize)
    }
}

private struct RouterEditView: View {
    let receipt: RouterReceipt
    let cancel: () -> Void
    let save: (String, RouterCategory) -> Void
    @State private var title: String
    @State private var category: RouterCategory
    init(receipt: RouterReceipt, cancel: @escaping () -> Void, save: @escaping (String, RouterCategory) -> Void) {
        self.receipt = receipt; self.cancel = cancel; self.save = save
        _title = State(initialValue: receipt.title ?? ""); _category = State(initialValue: receipt.category ?? .notes)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改名称与分类").font(.headline)
            TextField("资产名称", text: $title)
            RouterCategoryPicker(selection: $category)
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save(title, category) }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.buttonStyle(OmniDWorkspaceButtonStyle())
        }.padding(20).frame(width: 400)
    }
}

struct RouterSettingsView: View {
    @State private var page = "归档"
    @ObservedObject var model: RouterPanelModel
    let chooseArchive: () -> Void
    let chooseIndex: () -> Void
    let chooseTransfer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OmniDWorkspaceChoicePicker(title: "万有引力设置分类", selection: $page,
                choices: ["归档", "智能", "中转"].map { ($0, $0) }, segmented: true)
                .padding(.horizontal, 18).padding(.bottom, 6)
            Form {
                if page == "归档" { archiveSettings }
                if page == "智能" { intelligenceSettings }
                if page == "中转" { transferSettings }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
                .font(.system(size: 11)).controlSize(.small).toggleStyle(OmniDWorkspaceToggleStyle())
        }.disabled(model.choosing || model.savingTransfer).accessibilityLabel("万有引力目录与智能设置")
    }

    private var archiveSettings: some View {
        Group {
            Section("1 · 图片和文件存到哪里") {
                explanation("图片、PDF 和脚本都存这里。选择 iCloud Drive 或 Google Drive 中的一个位置，App 会整理到「万物仓」。")
                directory("文件存放位置", url: (model.selectedArchive ?? model.settings?.archive.location).map(RouterAccess.archiveLocation(in:)),
                    select: "选择存放位置…", change: "更换位置…", action: chooseArchive)
            }
            Section("2 · 在 Obsidian 记在哪里") {
                explanation("选择你平时在 Obsidian 打开的笔记库文件夹，也就是能看到已有笔记的那一层。")
                directory("Obsidian 笔记库", url: model.selectedIndex ?? model.settings?.indexParent.location,
                    select: "选择笔记库…", change: "更换笔记库…", action: chooseIndex)
                explanation("第一次归档后，笔记库里会出现「万有引力｜万物总索引.md」。以后每次归档自动添一条记录，点记录里的链接可找到文件。")
            }
            if !model.settingsMessage.isEmpty {
                Section { explanation(model.settingsMessage) }
            }
        }
    }

    private var intelligenceSettings: some View {
        Group {
            Section("1 · 获取 Google 智能识别密钥") {
                explanation("打开 Google AI Studio，登录你的 Google 账号，创建并复制 Gemini API 密钥，然后粘贴到下方。")
                if let url = URL(string: "https://aistudio.google.com/apikey") {
                    Link("打开 Google 页面获取 API 密钥", destination: url)
                }
                explanation("Google Drive 用来存文件；这里的 Gemini 用来识别内容。")
            }
            Section("2 · 粘贴密钥并启用") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Gemini API 密钥")
                    SecureField("在这里粘贴 API 密钥", text: $model.aiKeyDraft)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                        .accessibilityLabel("粘贴 Gemini API 密钥")
                    explanation(model.aiKeyAvailable ? "已保存密钥；留空会继续使用，粘贴新密钥可替换。" : "尚未保存密钥。可以通过上方 Google 页面获取。")
                }
                Toggle("启用 AI 智能识别", isOn: $model.aiEnabled)
                    .accessibilityLabel("启用 AI 智能识别")
                HStack {
                    Button("保存并应用") {
                        if model.aiKeyAvailable && !model.aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            OmniDWorkspaceNotice.confirm("替换已保存的密钥？", message: "以后使用新密钥进行智能识别，原密钥将从本 App 的钥匙串记录中替换。", confirmTitle: "替换密钥") { model.saveAI() }
                        } else { model.saveAI() }
                    }
                    Button("停用并移除密钥") {
                        OmniDWorkspaceNotice.confirm("停用智能识别并移除密钥？", message: "普通记录与归档仍可使用。再次使用智能识别时，需要重新填写密钥。", confirmTitle: "停用并移除") { model.saveAI(removeKey: true) }
                    }.disabled(!model.aiKeyAvailable)
                }.disabled(model.savingAI)
                if !model.aiSettingsMessage.isEmpty { explanation(model.aiSettingsMessage) }
            }
            Section("什么时候会使用 AI") {
                explanation("在万有引力里主动点「智能处理」才会发送网址或图片预览给 Google。普通记录保持本地处理；3 秒内没有结果就按原文归档。密钥保存在本机钥匙串。")
            }
        }
    }

    private var transferSettings: some View {
        Group {
            Section("1 · 创建手机收件箱") {
                explanation("手机分享的文字和文件先到这里。首次点下面按钮，在系统窗口允许访问一次，App 会自动建好 OmniD-Transfer 并开启接收。")
                directory("iCloud 手机收件箱", url: model.transferState.location,
                    select: "创建 iCloud 中转文件夹…", change: "重新连接…", action: chooseTransfer)
                Toggle("接收手机分享", isOn: Binding(get: { model.transferEnabled }, set: {
                    model.transferEnabled = $0; model.saveTransfer()
                })).disabled(model.transferState.location == nil)
                explanation(model.transferState.message)
                if !model.transferMessage.isEmpty { explanation(model.transferMessage) }
            }
            Section("2 · 添加手机快捷指令") {
                explanation("每位用户都能在这里添加。点按钮后，在系统「快捷指令」窗口点「添加快捷指令」。")
                shortcut("万有引力·记录", detail: "保存 Safari 网址、备忘录和文字")
                shortcut("万有引力·文件", detail: "保存照片、截图和普通文件")
                explanation("Mac「快捷指令 → 设置 → 通用」开启 iCloud 同步，并与手机使用同一 Apple 账号。手机没出现时，用上面的「发送到 iPhone / iPad」隔空投送。")
                if let url = URL(string: "https://support.apple.com/zh-cn/guide/shortcuts-mac/apdb3a4240b0/mac") {
                    Link("查看 Apple 的快捷指令同步步骤", destination: url)
                }
            }
            Section("3 · 在手机分享一次") {
                explanation("在 Safari、照片或「文件」里点分享，选择刚添加的指令。保存位置选「iCloud Drive → OmniD-Transfer」，关闭覆盖已有文件。Mac 收到后，打开万有引力，点「接收中转」并选择分类归档。")
                DisclosureGroup("以后怎样一步保存？") {
                    explanation("在手机「快捷指令」里长按对应指令 → 编辑，在「保存文件」动作关闭「询问保存位置」，再点文件夹并选择 iCloud Drive → OmniD-Transfer。每台设备分别设置一次。")
                }
                Button("复制完整手机操作步骤") {
                    NSPasteboard.general.clearContents()
                    model.transferMessage = NSPasteboard.general.setString(RouterTransfer.shortcutInstructions, forType: .string)
                        ? "操作步骤已复制，可粘贴到备忘录带到手机上看。" : "剪贴板写入失败，请重试。"
                }
            }
            if model.transferState.location != nil {
                Section {
                    Button("断开手机收件箱") {
                        OmniDWorkspaceNotice.confirm("断开手机收件箱？", message: "Mac 将停止接收手机分享。iCloud 收件箱里的文件和已归档内容都会保留。", confirmTitle: "断开连接") { model.saveTransfer(unbind: true) }
                    }.disabled(model.savingTransfer)
                    explanation("断开只停止接收，里面的文件会保留。")
                }
            }
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func directory(_ title: String, url: URL?, select: String, change: String,
                           action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(title); Spacer(); Button(url == nil ? select : change, action: action) }
            if let url {
                explanation(RouterAccess.displayLocation(url))
                HStack {
                    Button("在访达中查看") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Spacer()
                }
                DisclosureGroup("查看完整路径") {
                    Text(url.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            } else { explanation("尚未设置，点上方按钮开始。") }
        }
    }

    private func shortcut(_ name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name)
            explanation(detail)
            HStack {
                Button("添加到快捷指令") { model.addShortcut(name) }
                    .accessibilityLabel("添加" + name)
                Button("发送到 iPhone / iPad") { model.shareShortcut(name) }
                    .accessibilityLabel("发送" + name + "到手机或平板")
            }
        }
    }
}

struct RouterTransferAttention: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var preferences = OmniDWorkspacePreferences.shared
    @ObservedObject var model: RouterPanelModel
    let open: () -> Void
    var body: some View {
        if !model.transferState.items.isEmpty {
            Button(action: open) {
                Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && !preferences.reduceMotion)
            }.buttonStyle(.plain).frame(width: 20, height: 20)
                .accessibilityLabel("中转待收 \(model.transferState.items.count) 项，打开万有引力")
                .help("有中转文件待收；点击打开万有引力，选择分类后归档。")
        }
    }
}
