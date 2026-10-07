import SwiftUI
import UniformTypeIdentifiers

struct OffKeyNotesView: View {
    @ObservedObject var store: OffKeyNotesStore
    @State private var pendingTrashAction: TrashAction?

    private enum TrashAction: String, Identifiable {
        case selected
        case all

        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 170, idealWidth: 190, maxWidth: 230)
                .frame(maxHeight: .infinity, alignment: .top)
            editor
                .frame(minWidth: 350)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 12)).controlSize(.small)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .onDisappear { store.saveImmediately() }
        .alert(
            OffKeyL10n.text("offkey.notes.errorTitle", fallback: "记事"),
            isPresented: Binding(
                get: { store.presentedError != nil },
                set: { if !$0 { store.presentedError = nil } }
            )
        ) {
            Button(OffKeyL10n.text("offkey.common.ok", fallback: "好")) {
                store.presentedError = nil
            }
        } message: {
            Text(store.presentedError ?? "")
        }
        .confirmationDialog(
            "永久删除后无法恢复",
            item: $pendingTrashAction,
            titleVisibility: .visible
        ) { action in
            switch action {
            case .selected:
                Button("永久删除这条记录", role: .destructive) {
                    store.deleteSelectedPermanently()
                }
            case .all:
                Button("清空回收站", role: .destructive) {
                    store.emptyTrash()
                }
            }
            Button("取消", role: .cancel) {}
        } message: { action in
            Text(action == .all ? "回收站中的全部记录都将被删除。" : "这条记录将从本机永久删除。")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            TextField(
                "搜索记事",
                text: $store.query
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(OffKeyL10n.text("offkey.notes.search", fallback: "查找标题和内容"))
            .onChange(of: store.query) { _, _ in store.selectFirstVisibleIfNeeded() }

            Picker("", selection: $store.scope) {
                Text(OffKeyL10n.text("offkey.notes.records", fallback: "记录"))
                    .tag(OffKeyNotesStore.Scope.notes)
                Text(OffKeyL10n.text("offkey.notes.trash", fallback: "回收站"))
                    .tag(OffKeyNotesStore.Scope.trash)
            }
            .pickerStyle(.segmented).omniDSegmentedContrast()
            .labelsHidden()
            .onChange(of: store.scope) { _, _ in store.selectFirstVisibleIfNeeded() }

            List(store.visibleRecords, selection: $store.selectedID) { record in
                Text(record.title.isEmpty
                    ? OffKeyL10n.text("offkey.notes.untitled", fallback: "未命名记录")
                    : record.title)
                    .lineLimit(2)
                    .tag(record.id)
            }

            HStack {
                Button {
                    store.addNote()
                } label: {
                    Label(
                        OffKeyL10n.text("offkey.notes.add", fallback: "新建"),
                        systemImage: "plus"
                    )
                }
                .disabled(!store.isPersistenceAvailable)
                .accessibilityHint(OffKeyL10n.text("offkey.notes.addHint", fallback: "新建一条空白记录"))

                Spacer()

                Button {
                    if store.scope == .trash { store.moveSelected() }
                    else {
                        OmniDWorkspaceNotice.confirm("将这条记录移到回收站？", message: "以后可在记事回收站中恢复。", confirmTitle: "移到回收站") { store.moveSelected() }
                    }
                } label: {
                    Image(systemName: store.scope == .trash ? "arrow.uturn.backward" : "trash")
                }
                .accessibilityLabel(store.scope == .trash ? "恢复记录" : "移到回收站")
                .help(store.scope == .trash ? "恢复记录" : "移到回收站")
                .disabled(store.selectedRecord == nil || !store.isPersistenceAvailable)

                if store.scope == .trash {
                    Button(role: .destructive) {
                        pendingTrashAction = .selected
                    } label: {
                        Image(systemName: "trash.slash")
                    }
                    .accessibilityLabel("永久删除记录")
                    .help("永久删除记录")
                    .disabled(store.selectedRecord == nil || !store.isPersistenceAvailable)
                }
            }
            if store.scope == .trash && !store.document.trash.isEmpty {
                Button("清空回收站", role: .destructive) {
                    pendingTrashAction = .all
                }
                .font(.caption)
                .buttonStyle(.link)
                .disabled(!store.isPersistenceAvailable)
            }
            Button("备份与导出…") { SettingsWindowController.shared.showPrivacySettings() }
                .font(.caption).buttonStyle(.link)
        }
        .padding(12)
    }

    @ViewBuilder
    private var editor: some View {
        if let record = store.selectedRecord {
            VStack(alignment: .leading, spacing: 12) {
                TextField(
                    OffKeyL10n.text("offkey.notes.titlePlaceholder", fallback: "标题"),
                    text: Binding(
                        get: { store.selectedRecord?.title ?? "" },
                        set: { store.updateSelected(title: $0) }
                    )
                )
                .font(.system(size: 17, weight: .semibold))
                .textFieldStyle(.plain)
                .disabled(store.scope == .trash || !store.isPersistenceAvailable)
                .accessibilityLabel(OffKeyL10n.text("offkey.notes.title", fallback: "标题"))

                Divider()

                TextEditor(text: Binding(
                    get: { store.selectedRecord?.notes ?? "" },
                    set: { store.updateSelected(notes: $0) }
                ))
                .font(.body)
                .disabled(store.scope == .trash || !store.isPersistenceAvailable)
                .accessibilityLabel(OffKeyL10n.text("offkey.notes.content", fallback: "内容"))

                Divider()

                actionBar(for: record)
            }
            .padding(14)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "note.text").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(store.scope == .trash ? "回收站为空" : "没有记录")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                if !store.statusMessage.isEmpty {
                    Text(store.statusMessage).font(.caption)
                        .foregroundStyle(store.hasUnsavedChanges ? .orange : .secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(14)
        }
    }

    private func actionBar(for record: OffKeyNoteRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(OffKeyL10n.text("offkey.notes.copyTitle", fallback: "复制标题")) {
                    store.copyTitle()
                }
                Button(OffKeyL10n.text("offkey.notes.copyAll", fallback: "复制全部")) {
                    store.copyAll()
                }
                Spacer()
            }
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(store.hasUnsavedChanges ? .orange : .secondary)
                .lineLimit(2)
                .accessibilityLabel(store.statusMessage)
        }
    }

}

struct OffKeyNotesTransferControls: View {
    @ObservedObject var store: OffKeyNotesStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu(OffKeyL10n.text("offkey.notes.import", fallback: "导入 JSON…")) {
                Button(OffKeyL10n.text("offkey.notes.merge", fallback: "加入当前记录")) {
                    chooseImport(mode: .merge)
                }
                Button(OffKeyL10n.text("offkey.notes.replace", fallback: "替换当前记录")) {
                    chooseImport(mode: .replace)
                }
            }
            .disabled(!store.isPersistenceAvailable)
            Button(OffKeyL10n.text("offkey.notes.restoreBackup", fallback: "恢复导入前备份")) {
                OmniDWorkspaceNotice.confirm("恢复导入前的记录？", message: "当前记录将被备份中的内容替换。恢复前的内容会另存为备份。", confirmTitle: "恢复备份") { store.restoreImportBackup() }
            }
            .disabled(!store.isPersistenceAvailable)
            Button(OffKeyL10n.text("offkey.notes.export", fallback: "导出 JSON…")) {
                chooseExport()
            }
        }
    }

    private func chooseImport(mode: OffKeyNotesImportMode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if mode == .replace {
            OmniDWorkspaceNotice.confirm("替换当前全部记录？", message: "将使用「\(url.lastPathComponent)」里的记录替换当前内容。现有记录会先备份，可通过「恢复导入前备份」找回。", confirmTitle: "替换记录") { store.importJSON(from: url, mode: mode) }
        } else { store.importJSON(from: url, mode: mode) }
    }

    private func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OmniD-Pod-记事.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportJSON(to: url)
    }
}
