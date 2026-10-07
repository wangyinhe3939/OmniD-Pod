import Foundation

// Runs the actual note store with an injected repository, never the user's data.
@main
struct CheckWorkspace {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("boringNotch.xcodeproj/project.pbxproj").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("boringNotch/offkey/Core/OffKeyNotesCore.swift").path)
        else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = root.appendingPathComponent(".build_tmp/WorkspaceCheck", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let repository = OffKeyNotesRepository(storeURL: directory.appendingPathComponent("Notes.json"))
        let original = OffKeyNotesDocument(entries: [OffKeyNoteRecord(id: "original", title: "原记事", notes: "原文")])
        try repository.save(original)
        let notes = OffKeyNotesStore(repository: repository)
        notes.updateWorkspaceDraft(text: "  灵感第一行\n原文第二行  ", project: "项目甲")
        precondition(notes.saveImmediately())
        let savedDraft = try repository.load().workspaceDraft
        precondition(savedDraft?.text == "  灵感第一行\n原文第二行  ")
        precondition(notes.saveWorkspaceCapture(isTask: false))
        precondition(notes.document.entries.count == 2, "普通多行原文不能自动拆散")
        precondition(notes.document.entries[0].notes == "  灵感第一行\n原文第二行  ", "普通输入须逐字保留原文")
        precondition(notes.workspaceDraft.text.isEmpty)
        let id = notes.document.entries[0].id
        precondition(notes.toggleWorkspaceRecord(id: id))
        precondition(notes.document.workspaceRecords(isTask: true, showCompleted: false).count == 1)
        precondition(notes.toggleWorkspaceRecord(id: id))
        precondition(notes.document.workspaceRecords(isTask: true, showCompleted: false).isEmpty)
        precondition(notes.toggleWorkspaceRecord(id: id), "完成可恢复")
        notes.updateWorkspaceDraft(text: "一件事\n\n第二件事")
        precondition(notes.saveWorkspaceCapture(isTask: true, separateLines: true))
        precondition(notes.document.entries.count == 4)
        precondition(notes.document.entries.prefix(2).map(\.title) == ["一件事", "第二件事"])
        let reloaded = try repository.load()
        precondition(reloaded == notes.document)
        precondition(reloaded.entries.first(where: { $0.id == "original" }) == original.entries[0])
        let backup = try repository.decodeDocument(from: Data(contentsOf: directory.appendingPathComponent("Notes-before-workspace.json")))
        precondition(backup == original)
        notes.updateWorkspaceDraft(text: "写入失败也不丢")
        let before = notes.document
        try FileManager.default.moveItem(at: repository.storeURL, to: directory.appendingPathComponent("before-failure.json"))
        try FileManager.default.createDirectory(at: repository.storeURL, withIntermediateDirectories: false)
        precondition(!notes.saveWorkspaceCapture(isTask: true))
        precondition(notes.document == before && notes.presentedError != nil)
        print("实际记事存储检查通过：草稿读回、原文保留、待办转换、完成恢复、批量确认、失败不丢内容。")
    }
}
