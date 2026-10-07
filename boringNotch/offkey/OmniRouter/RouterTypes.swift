import Foundation

enum RouterCategory: String, Codable, CaseIterable, Identifiable {
    case visual = "视觉资产", notes = "构想与纪要", tools = "工具与脚本", reference = "灵感参考"
    var id: String { rawValue }
}

enum RouterPhase: String, Codable {
    case queued, staging, fileCommitted, indexCommitted, sourceCleanupPending, complete
    case accessRequired, indexPending, sourceRetained, conflict, failed
    case editing, undoPending, undone
    var label: String {
        switch self {
        case .queued: return "已接收"
        case .staging: return "正在归档"
        case .fileCommitted: return "已写入同步目录"
        case .indexCommitted, .sourceCleanupPending: return "索引已写入，正在清理原位置"
        case .complete: return "已归档并写入索引（云端同步未确认）"
        case .accessRequired: return "需重新授权"
        case .indexPending: return "索引待补写"
        case .sourceRetained: return "原文件待清理"
        case .conflict: return "冲突，原文件保留"
        case .failed: return "归档失败，输入保留"
        case .editing: return "名称与分类修改待完成"
        case .undoPending: return "撤销待完成"
        case .undone: return "已撤销"
        }
    }
}

struct RouterBookmark: Codable {
    let data: Data
    let securityScoped: Bool
    let location: URL?
}

struct RouterSettings: Codable {
    var archive: RouterBookmark
    var indexParent: RouterBookmark
}

enum RouterPayload: Codable {
    case text(String)
    case web(String)
    case file(bookmark: RouterBookmark)
}

struct RouterFingerprint: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: TimeInterval
    let permissions: UInt16
    let digest: String
    func hasSameContent(as other: Self) -> Bool { size == other.size && digest == other.digest }
}

struct RouterTransaction: Codable {
    let operationID: UUID
    var category: RouterCategory
    var payload: RouterPayload
    var settings: RouterSettings
    let created: Date
    var phase: RouterPhase = .queued
    var source: RouterFingerprint?
    var sourceLocation: URL?
    var archived: RouterFingerprint?
    var destination: URL?
    var stage: URL?
    var indexLine: String?
    var indexParentLocation: URL?
    var message: String = ""
    // Optional fields keep first-stage journals readable without a migration or data rewrite.
    var displayName: String?
    var mutation: RouterHistoryMutation?
    var trashedLocation: URL?
    var enrichment: RouterEnrichment?
    var intelligenceNote: String?

    var title: String {
        if let displayName { return displayName }
        switch payload {
        case .file(let bookmark): return sourceLocation?.lastPathComponent ?? bookmark.location?.lastPathComponent ?? "文件"
        case .text(let text), .web(let text): return String(text.components(separatedBy: .newlines).first?.prefix(160) ?? "原文")
        }
    }
}

struct RouterHistoryMutation: Codable {
    enum Kind: String, Codable { case edit, trash }
    let kind: Kind
    let from: URL
    let to: URL
    let title: String
    let category: RouterCategory
    let oldLine: String
    let newLine: String?
    let previousPhase: RouterPhase
    var indexChanged: Bool?
}

struct RouterReceipt {
    let operationID: UUID
    let phase: RouterPhase
    let message: String
    let destination: URL?
    var title: String?
    var category: RouterCategory?
    var created: Date?
    var canEdit = false

    init(operationID: UUID, phase: RouterPhase, message: String, destination: URL?) {
        self.operationID = operationID; self.phase = phase; self.message = message; self.destination = destination
    }

    init(_ transaction: RouterTransaction) {
        self.init(operationID: transaction.operationID, phase: transaction.phase,
                  message: transaction.message, destination: transaction.destination)
        title = transaction.title; category = transaction.category; created = transaction.created
        canEdit = transaction.mutation == nil && [.complete, .sourceRetained].contains(transaction.phase)
    }

    var obsidianLink: String? {
        guard let destination, let title else { return nil }
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .components(separatedBy: .newlines).joined(separator: " ")
        return "[\(escaped)](<\(destination.absoluteString)>)"
    }
}

enum RouterFailure: LocalizedError {
    case access(String), conflict(String), changed, invalid(String), io(String)
    static func message(for error: Error) -> String {
        if let failure = error as? RouterFailure { return failure.errorDescription ?? "文件操作失败，原输入保留。" }
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain {
            switch POSIXErrorCode(rawValue: Int32(clamping: failure.code)) {
            case .ENOSPC: return "磁盘空间不足，原输入保留，请释放空间后重试。"
            case .EROFS: return "目标目录只读，原输入保留，请重新选择可写目录。"
            case .EACCES, .EPERM: return "没有访问权限，请重新授权目录，原输入保留。"
            case .ENOENT: return "文件或目录不存在，请检查原位置后重试。"
            case .EEXIST: return "目标已有同名文件，未覆盖，请修改名称后重试。"
            default: break
            }
        } else if failure.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: failure.code) {
            case .fileWriteOutOfSpace: return "磁盘空间不足，原输入保留，请释放空间后重试。"
            case .fileWriteVolumeReadOnly: return "目标目录只读，原输入保留，请重新选择可写目录。"
            case .fileReadNoPermission, .fileWriteNoPermission: return "没有访问权限，请重新授权目录，原输入保留。"
            case .fileNoSuchFile, .fileReadNoSuchFile: return "文件或目录不存在，请检查原位置后重试。"
            case .fileReadCorruptFile, .coderReadCorrupt, .propertyListReadCorrupt:
                return "本地数据不可读取，请检查事务日志并重新授权目录。"
            default: break
            }
        }
        return "文件操作失败（错误码 \(failure.code)），请检查目录授权、磁盘空间与文件状态。"
    }
    var errorDescription: String? {
        switch self {
        case .access(let message), .conflict(let message), .invalid(let message), .io(let message): return message
        case .changed: return "源文件已变化，保留原文件。"
        }
    }
}

// Explicit dependency for generated-fixture fault checks; production uses the no-op closure.
enum RouterCheckpoint: String, CaseIterable {
    case intent, staged, committed, indexed, cleanupPending, cleaned
    case copy, indexWrite, sourceCleanup
    case historyIntent, historyMoved, historyIndexed, historyTrashed
}
