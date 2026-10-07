import Foundation

struct OffKeyWorkspaceMetadata: Codable, Equatable, Hashable {
    var isTask: Bool
    var createdAt: Date = Date()
    var scheduledDate: Date?
    var completed = false
    var project = ""
    var reminderDate: Date?
    var reminderIdentifier: String?
}

struct OffKeyWorkspaceDraft: Codable, Equatable {
    var text = ""
    var project = ""
    var reminderDate: Date?
}

struct OffKeyNoteRecord: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var title: String
    var notes: String
    var workspace: OffKeyWorkspaceMetadata?

    init(id: String = UUID().uuidString, title: String = "", notes: String = "",
         workspace: OffKeyWorkspaceMetadata? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.workspace = workspace
    }

    var workspaceText: String { notes.isEmpty ? title : notes }
}

struct OffKeyNotesDocument: Codable, Equatable {
    static let currentFormat = "double-meaning-notes"
    static let currentVersion = 1
    static let maxTitleCount = 2_000
    static let maxNotesCount = 100_000

    var format = Self.currentFormat
    var version = Self.currentVersion
    var entries: [OffKeyNoteRecord] = []
    var trash: [OffKeyNoteRecord] = []
    var workspaceDraft: OffKeyWorkspaceDraft?

    static let empty = Self()

    func validated() throws -> Self {
        guard format == Self.currentFormat, version == Self.currentVersion else {
            throw OffKeyNotesError.unsupportedDocument
        }

        var identifiers = Set<String>()
        var reminderIdentifiers = Set<String>()
        if let draft = workspaceDraft {
            guard draft.text.count <= Self.maxNotesCount, draft.project.count <= 100,
                  draft.reminderDate?.timeIntervalSince1970.isFinite ?? true else {
                throw OffKeyNotesError.invalidRecord
            }
        }
        for record in entries + trash {
            guard !record.id.isEmpty,
                  record.id.count <= 100,
                  identifiers.insert(record.id).inserted
            else {
                throw OffKeyNotesError.invalidRecord
            }
            guard record.title.count <= Self.maxTitleCount else {
                throw OffKeyNotesError.titleTooLong
            }
            guard record.notes.count <= Self.maxNotesCount else {
                throw OffKeyNotesError.notesTooLong
            }
            if let metadata = record.workspace {
                guard metadata.project.count <= 100,
                      [metadata.createdAt, metadata.scheduledDate, metadata.reminderDate].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                      metadata.reminderIdentifier.map({ !$0.isEmpty && $0.count <= 1_000 && reminderIdentifiers.insert($0).inserted }) ?? true
                else { throw OffKeyNotesError.invalidRecord }
            }
        }
        return self
    }

    func workspaceRecords(isTask: Bool, showCompleted: Bool, project: String = "",
                          now: Date = Date(), calendar: Calendar = .current) -> [OffKeyNoteRecord] {
        entries.filter { record in
            let metadata = record.workspace
            guard (metadata?.isTask ?? false) == isTask,
                  project.isEmpty || metadata?.project == project else { return false }
            if !isTask { return true }
            guard showCompleted || metadata?.completed != true else { return false }
            // Undated items are not overdue. Unfinished dated items carry forward.
            guard let date = metadata?.scheduledDate else { return true }
            return calendar.startOfDay(for: date) <= calendar.startOfDay(for: now)
        }
    }

    func matching(_ query: String, inTrash: Bool) -> [OffKeyNoteRecord] {
        let source = inTrash ? trash : entries
        let terms = query
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        guard !terms.isEmpty else { return source }

        return source.filter { record in
            let value = record.title + " " + record.notes
            return terms.allSatisfy {
                value.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    @discardableResult
    mutating func permanentlyDeleteTrashRecord(id: String) -> Bool {
        guard let index = trash.firstIndex(where: { $0.id == id }) else { return false }
        trash.remove(at: index)
        return true
    }

    @discardableResult
    mutating func emptyTrash() -> Int {
        let removedCount = trash.count
        trash.removeAll()
        return removedCount
    }
}

enum OffKeyNotesImportMode {
    case merge
    case replace
}

enum OffKeyNotesError: LocalizedError {
    case unsupportedDocument
    case invalidRecord
    case noImportBackup
    case applicationSupportUnavailable
    case titleTooLong
    case notesTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedDocument:
            return "请选择 DD 刘海记事导出的 JSON 备份。"
        case .invalidRecord:
            return "备份中的记录有误，当前记事没有改动。"
        case .noImportBackup:
            return "没有可恢复的导入前备份。"
        case .applicationSupportUnavailable:
            return "无法打开 DD 刘海的本地数据目录。"
        case .titleTooLong:
            return "标题最多 \(OffKeyNotesDocument.maxTitleCount) 字；本次修改没有保存。"
        case .notesTooLong:
            return "正文最多 \(OffKeyNotesDocument.maxNotesCount) 字；本次修改没有保存。"
        }
    }
}

struct OffKeyNotesRepository {
    let storeURL: URL
    let fileManager: FileManager

    init(storeURL: URL, fileManager: FileManager = .default) {
        self.storeURL = storeURL
        self.fileManager = fileManager
    }

    static func applicationRepository(fileManager: FileManager = .default) throws -> Self {
        guard let supportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw OffKeyNotesError.applicationSupportUnavailable
        }
        let directory = supportURL.appendingPathComponent("DD刘海", isDirectory: true)
        return Self(
            storeURL: directory.appendingPathComponent("Notes.json"),
            fileManager: fileManager
        )
    }

    var importBackupURL: URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("Notes-before-import.json")
    }

    var restoreRollbackURL: URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("Notes-before-restore.json")
    }

    func load() throws -> OffKeyNotesDocument {
        guard fileManager.fileExists(atPath: storeURL.path) else { return .empty }
        return try decodeDocument(from: Data(contentsOf: storeURL))
    }

    func decodeDocument(from data: Data) throws -> OffKeyNotesDocument {
        do {
            return try JSONDecoder().decode(OffKeyNotesDocument.self, from: data).validated()
        } catch let error as OffKeyNotesError {
            throw error
        } catch {
            throw OffKeyNotesError.invalidRecord
        }
    }

    func save(_ document: OffKeyNotesDocument) throws {
        let validated = try document.validated()
        if validated.workspaceDraft != nil || validated.entries.contains(where: { $0.workspace != nil }) {
            let backup = storeURL.deletingLastPathComponent().appendingPathComponent("Notes-before-workspace.json")
            if fileManager.fileExists(atPath: storeURL.path), !fileManager.fileExists(atPath: backup.path) {
                // Preserve the original bytes once, before the first workspace write.
                try fileManager.copyItem(at: storeURL, to: backup)
            }
        }
        try write(validated, to: storeURL)
    }

    func export(_ document: OffKeyNotesDocument, to destination: URL) throws {
        try write(document.validated(), to: destination)
    }

    func importDocument(
        _ incoming: OffKeyNotesDocument,
        into current: OffKeyNotesDocument,
        mode: OffKeyNotesImportMode
    ) throws -> (document: OffKeyNotesDocument, addedCount: Int) {
        let validatedCurrent = try current.validated()
        let validatedIncoming = try incoming.validated()
        let result: (OffKeyNotesDocument, Int)

        switch mode {
        case .replace:
            result = (validatedIncoming, validatedIncoming.entries.count + validatedIncoming.trash.count)
        case .merge:
            result = try merge(incoming: validatedIncoming, into: validatedCurrent)
        }

        try write(validatedCurrent, to: importBackupURL)
        try save(result.0)
        return result
    }

    func restoreImportBackup() throws -> OffKeyNotesDocument {
        guard fileManager.fileExists(atPath: importBackupURL.path) else {
            throw OffKeyNotesError.noImportBackup
        }
        let document = try decodeDocument(from: Data(contentsOf: importBackupURL))
        try write(try load().validated(), to: restoreRollbackURL)
        try save(document)
        return document
    }

    private func merge(
        incoming: OffKeyNotesDocument,
        into current: OffKeyNotesDocument
    ) throws -> (OffKeyNotesDocument, Int) {
        var result = current
        var identifiers = Set((current.entries + current.trash).map(\.id))
        let existing = current.entries + current.trash
        var added = 0

        func mergedRecord(_ record: OffKeyNoteRecord) -> OffKeyNoteRecord? {
            if existing.contains(where: {
                $0 == record
            }) {
                return nil
            }
            var copy = record
            while identifiers.contains(copy.id) {
                copy.id = UUID().uuidString
            }
            identifiers.insert(copy.id)
            return copy
        }

        for record in incoming.entries {
            if let copy = mergedRecord(record) {
                result.entries.append(copy)
                added += 1
            }
        }
        for record in incoming.trash {
            if let copy = mergedRecord(record) {
                result.trash.append(copy)
                added += 1
            }
        }

        return (try result.validated(), added)
    }

    private func write(_ document: OffKeyNotesDocument, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
