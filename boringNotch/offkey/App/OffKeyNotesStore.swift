import AppKit
import Combine
import Foundation

@MainActor
final class OffKeyNotesStore: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case notes
        case trash

        var id: String { rawValue }
    }

    @Published private(set) var document: OffKeyNotesDocument
    @Published var scope: Scope = .notes
    @Published var query = ""
    @Published var selectedID: String?
    @Published private(set) var statusMessage = ""
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var isPersistenceAvailable = true
    @Published var presentedError: String?

    private let repository: OffKeyNotesRepository?
    private var saveTask: Task<Void, Never>?

    init(repository: OffKeyNotesRepository? = nil) {
        let initialization: (
            repository: OffKeyNotesRepository?,
            document: OffKeyNotesDocument,
            error: Error?
        )

        do {
            let resolved = try repository ?? OffKeyNotesRepository.applicationRepository()
            let loaded = try resolved.load()
            initialization = (resolved, loaded, nil)
        } catch {
            initialization = (nil, .empty, error)
        }

        self.repository = initialization.repository
        document = initialization.document
        selectedID = initialization.document.entries.first?.id

        if let persistenceError = initialization.error {
            isPersistenceAvailable = false
            statusMessage = "本地数据目录不可用，记事已设为只读。"
            presentedError = persistenceError.localizedDescription
        }
    }

    deinit {
        saveTask?.cancel()
    }

    var visibleRecords: [OffKeyNoteRecord] {
        document.matching(query, inTrash: scope == .trash)
    }

    var selectedRecord: OffKeyNoteRecord? {
        guard let selectedID else { return nil }
        return records(for: scope).first { $0.id == selectedID }
    }

    var workspaceDraft: OffKeyWorkspaceDraft { document.workspaceDraft ?? OffKeyWorkspaceDraft() }

    func updateWorkspaceDraft(text: String? = nil, project: String? = nil, reminderDate: Date? = nil,
                              changesReminder: Bool = false) {
        guard requireRepository() != nil else { return }
        var draft = workspaceDraft
        if let text {
            guard text.count <= OffKeyNotesDocument.maxNotesCount else {
                rejectEdit(.notesTooLong)
                return
            }
            draft.text = text
        }
        if let project { draft.project = String(project.prefix(100)) }
        if changesReminder { draft.reminderDate = reminderDate }
        document.workspaceDraft = draft
        scheduleSave()
    }

    @discardableResult
    func saveWorkspaceCapture(isTask: Bool, now: Date = Date(), separateLines: Bool = false) -> Bool {
        let draft = workspaceDraft
        let text = draft.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let values = separateLines
            ? text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : [text]
        var candidate = document
        for value in values.reversed() {
            let metadata = OffKeyWorkspaceMetadata(isTask: isTask, createdAt: now,
                scheduledDate: isTask ? now : nil, project: draft.project,
                reminderDate: isTask ? draft.reminderDate : nil)
            candidate.entries.insert(OffKeyNoteRecord(
                title: String((value.components(separatedBy: .newlines).first ?? value).prefix(OffKeyNotesDocument.maxTitleCount)),
                notes: value, workspace: metadata), at: 0)
        }
        candidate.workspaceDraft = OffKeyWorkspaceDraft()
        return commitWorkspace(candidate, message: "已保存 \(values.count) 条")
    }

    @discardableResult
    func toggleWorkspaceRecord(id: String, now: Date = Date()) -> Bool {
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = document
        var metadata = candidate.entries[index].workspace ?? OffKeyWorkspaceMetadata(isTask: false)
        if metadata.isTask {
            metadata.completed.toggle()
        } else {
            metadata.isTask = true
            metadata.scheduledDate = now
            metadata.completed = false
        }
        candidate.entries[index].workspace = metadata
        return commitWorkspace(candidate, message: metadata.completed ? "已完成；可在已完成中恢复" : "已加入待办")
    }

    @discardableResult
    private func commitWorkspace(_ candidate: OffKeyNotesDocument, message: String) -> Bool {
        guard let repository = requireRepository() else { return false }
        saveTask?.cancel()
        do {
            try repository.save(candidate)
            document = candidate
            hasUnsavedChanges = false
            statusMessage = message
            return true
        } catch {
            statusMessage = "未保存，内容仍保留：\(error.localizedDescription)"
            presentedError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateWorkspaceRecord(id: String, edit: (inout OffKeyNoteRecord) -> Void) -> Bool {
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = document
        edit(&candidate.entries[index])
        return commitWorkspace(candidate, message: "已保存")
    }

    @discardableResult
    func insertWorkspaceReminder(id: String, title: String, text: String, metadata: OffKeyWorkspaceMetadata) -> Bool {
        var candidate = document
        candidate.entries.append(OffKeyNoteRecord(id: id, title: title, notes: text, workspace: metadata))
        return commitWorkspace(candidate, message: "已读回提醒事项")
    }

    @discardableResult
    func archiveWorkspaceRecord(id: String) -> Bool {
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = document
        candidate.trash.append(candidate.entries.remove(at: index))
        return commitWorkspace(candidate, message: "系统已移除此事项；原文保留在回收站")
    }

    func addNote() {
        guard requireRepository() != nil else { return }
        scope = .notes
        let note = OffKeyNoteRecord()
        document.entries.insert(note, at: 0)
        selectedID = note.id
        scheduleSave()
    }

    func updateSelected(title: String? = nil, notes: String? = nil) {
        guard requireRepository() != nil else { return }
        guard scope == .notes,
              let selectedID,
              let index = document.entries.firstIndex(where: { $0.id == selectedID })
        else { return }
        if let title, title.count > OffKeyNotesDocument.maxTitleCount {
            rejectEdit(OffKeyNotesError.titleTooLong)
            return
        }
        if let notes, notes.count > OffKeyNotesDocument.maxNotesCount {
            rejectEdit(OffKeyNotesError.notesTooLong)
            return
        }
        if let title { document.entries[index].title = title }
        if let notes { document.entries[index].notes = notes }
        scheduleSave()
    }

    func moveSelected() {
        guard requireRepository() != nil else { return }
        guard let selectedID else { return }
        switch scope {
        case .notes:
            guard let index = document.entries.firstIndex(where: { $0.id == selectedID }) else { return }
            let value = document.entries.remove(at: index)
            document.trash.insert(value, at: 0)
        case .trash:
            guard let index = document.trash.firstIndex(where: { $0.id == selectedID }) else { return }
            let value = document.trash.remove(at: index)
            document.entries.insert(value, at: 0)
        }
        self.selectedID = visibleRecords.first?.id
        scheduleSave()
    }

    func deleteSelectedPermanently() {
        guard requireRepository() != nil, scope == .trash, let selectedID else { return }
        guard document.permanentlyDeleteTrashRecord(id: selectedID) else { return }
        self.selectedID = visibleRecords.first?.id
        scheduleSave()
    }

    func emptyTrash() {
        guard requireRepository() != nil, scope == .trash else { return }
        guard document.emptyTrash() > 0 else { return }
        selectedID = nil
        scheduleSave()
    }

    func selectFirstVisibleIfNeeded() {
        if !visibleRecords.contains(where: { $0.id == selectedID }) {
            selectedID = visibleRecords.first?.id
        }
    }

    func copyTitle() {
        copy(selectedRecord?.title ?? "")
    }

    func copyAll() {
        guard let selectedRecord else { return }
        copy([selectedRecord.title, selectedRecord.notes]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n"))
    }

    func importJSON(from url: URL, mode: OffKeyNotesImportMode) {
        guard let repository = requireRepository() else { return }
        do {
            let incoming = try repository.decodeDocument(from: Data(contentsOf: url))
            let result = try repository.importDocument(incoming, into: document, mode: mode)
            document = result.document
            scope = .notes
            selectedID = document.entries.first?.id
            hasUnsavedChanges = false
            statusMessage = mode == .merge
                ? "已加入 \(result.addedCount) 条；已保留导入前备份"
                : "已替换；已保留导入前备份"
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func restoreImportBackup() {
        guard let repository = requireRepository() else { return }
        guard saveImmediately() else { return }
        do {
            document = try repository.restoreImportBackup()
            scope = .notes
            selectedID = document.entries.first?.id
            hasUnsavedChanges = false
            statusMessage = "已恢复导入前备份；恢复前内容已另存"
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func exportJSON(to url: URL) {
        guard let repository = requireRepository() else { return }
        do {
            try repository.export(document, to: url)
            statusMessage = "已导出"
        } catch {
            presentedError = error.localizedDescription
        }
    }

    @discardableResult
    func saveImmediately() -> Bool {
        saveTask?.cancel()
        guard hasUnsavedChanges else { return true }
        guard let repository else {
            isPersistenceAvailable = false
            statusMessage = "本地数据目录不可用，未保存内容仍保留在窗口中。"
            presentedError = OffKeyNotesError.applicationSupportUnavailable.localizedDescription
            return false
        }
        do {
            try repository.save(document)
            hasUnsavedChanges = false
            statusMessage = "已保存"
            return true
        } catch {
            hasUnsavedChanges = true
            statusMessage = "未保存：\(error.localizedDescription)。关闭前请复制或导出。"
            presentedError = error.localizedDescription
            return false
        }
    }

    private func records(for scope: Scope) -> [OffKeyNoteRecord] {
        scope == .trash ? document.trash : document.entries
    }

    private func scheduleSave() {
        guard repository != nil else { return }
        hasUnsavedChanges = true
        statusMessage = "正在保存…"
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.saveImmediately()
        }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusMessage = "已复制"
    }

    private func rejectEdit(_ error: OffKeyNotesError) {
        statusMessage = error.localizedDescription
        presentedError = error.localizedDescription
    }

    @discardableResult
    private func requireRepository() -> OffKeyNotesRepository? {
        guard let repository else {
            isPersistenceAvailable = false
            statusMessage = "本地数据目录不可用，记事保持只读。"
            presentedError = OffKeyNotesError.applicationSupportUnavailable.localizedDescription
            return nil
        }
        return repository
    }
}
