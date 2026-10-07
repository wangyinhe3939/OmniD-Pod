import Darwin
import Foundation

final class MarkdownIndexWriter {
    private static let queue = DispatchQueue(label: "OmniRouter.index", target: .global(qos: .utility))

    static func line(id: UUID, category: RouterCategory, destination: URL, summary: String,
                     created: Date? = nil, payload: RouterPayload? = nil, enrichment: RouterEnrichment? = nil) -> String {
        let escaped = String(summary.prefix(160)).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
        let marker = "<!-- OmniRouter:\(id.uuidString) -->"
        // Retain the original representation for old journals and their recovery checks.
        guard let created, let payload else {
            return "\(marker) - [\(escaped)](<\(destination.absoluteString)>) · \(category.rawValue)\n"
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH:mm"
        let form: String
        var note: String
        switch payload {
        case .text:
            form = "文字 Markdown"; note = "文字录入；原文完整保存在归档文件"
        case .web(let original):
            form = "网址 Markdown"; note = "网址录入；原始链接：" + original
        case .file(let bookmark):
            let ext = destination.pathExtension.uppercased()
            let images = ["PNG", "JPG", "JPEG", "GIF", "WEBP", "HEIC", "TIFF", "BMP", "SVG"]
            form = ext.isEmpty ? "普通文件" : (images.contains(ext) ? "图片 " : "文件 ") + ext
            note = "文件归档；原名称：" + (bookmark.location?.lastPathComponent ?? summary)
        }
        if let enrichment { note += "；" + enrichment.remark }
        var path = destination.path
        let home = NSHomeDirectoryForUser(NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        if path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { path = destination.absoluteString }
        let fence = String(repeating: "`", count: 1 + (path.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0))
        let pad = path.hasPrefix("`") || path.hasSuffix("`") || path.hasPrefix(" ") || path.hasSuffix(" ") ? " " : ""
        let title = escaped.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
        let remark = note.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "- [\(date.string(from: created))] **#\(category.rawValue)** :: \(title) \(marker)\n"
            + "  - 形式: \(form)\n  - 物理路径: \(fence)\(pad)\(path)\(pad)\(fence)\n"
            + "  - 来源/备注: \(remark)\(category == .tools ? "；仅归档，不执行" : "")\n"
    }

    func append(_ line: String, id: UUID, parent: URL, beforeWrite: () throws -> Void = {}) throws {
        guard !Thread.isMainThread else { throw RouterFailure.io("索引写入必须在后台执行。") }
        try Self.queue.sync {
            let url = parent.appendingPathComponent(RouterAccess.indexName)
            try RouterIO.coordinated(url, writing: true) { location in
                let handle: FileHandle
                do { handle = try RouterIO.open(location, flags: O_RDWR | O_APPEND | O_CREAT | O_EXCL) }
                catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                    try RouterIO.regular(location)
                    handle = try RouterIO.open(location, flags: O_RDWR | O_APPEND)
                }
                let expected = Data(line.utf8)
                let marker = Data("<!-- OmniRouter:\(id.uuidString) -->".utf8)
                guard let firstNewline = expected.firstIndex(of: 10), expected.last == 10,
                      expected.count <= 1_048_576 else {
                    throw RouterFailure.invalid("索引记录缺少操作标记、换行或超过长度限制。")
                }
                let firstRow = Data(expected.prefix(through: firstNewline))
                guard firstRow.range(of: marker) != nil else { throw RouterFailure.invalid("索引首行缺少操作标记。") }
                var identity: NSNumber?
                try RouterIO.handle(handle) { file in
                    identity = try FileManager.default.attributesOfItem(atPath: location.path)[.systemFileNumber] as? NSNumber
                    var buffer = Data()
                    var ownedOffset: UInt64?
                    var scanned: UInt64 = 0
                    while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 10) {
                            let row = Data(buffer.prefix(through: newline))
                            guard String(data: row, encoding: .utf8) != nil else { throw RouterFailure.conflict("索引不是有效 UTF-8，未改写。") }
                            if row.range(of: marker) != nil {
                                guard ownedOffset == nil, row == firstRow else {
                                    throw RouterFailure.conflict("索引存在重复或位置异常的操作标记，未改写。")
                                }
                                ownedOffset = scanned
                            }
                            scanned += UInt64(row.count)
                            buffer.removeSubrange(...newline)
                        }
                        guard buffer.count <= 1_048_576 else { throw RouterFailure.conflict("索引存在超长行，未改写。") }
                    }
                    let observed = try file.offset()
                    if ownedOffset == nil, !buffer.isEmpty {
                        guard buffer.range(of: marker) != nil else {
                            throw RouterFailure.conflict("索引尾部存在不完整或外部写入的行，保留待补写。")
                        }
                        ownedOffset = scanned
                    }
                    var suffix = expected
                    let recordOffset = ownedOffset ?? observed
                    if ownedOffset != nil {
                        try file.seek(toOffset: recordOffset)
                        let existing = try Self.read(file, count: expected.count)
                        guard expected.starts(with: existing) else {
                            throw RouterFailure.conflict("同一操作 ID 的索引内容不同，未改写。")
                        }
                        if existing == expected {
                            guard buffer.isEmpty else { throw RouterFailure.conflict("索引存在未完成的外部尾部，保留待补写。") }
                            try file.synchronize(); return
                        }
                        guard recordOffset + UInt64(existing.count) == observed else {
                            throw RouterFailure.conflict("索引记录不完整且后方存在外部内容，未改写。")
                        }
                        suffix = Data(expected.dropFirst(existing.count))
                    }
                    try beforeWrite()
                    let end = try file.seekToEnd()
                    guard end == observed else { throw RouterFailure.conflict("扫描后索引被外部追加，保留待补写。") }
                    try file.write(contentsOf: suffix)
                    try file.synchronize()
                    try file.seek(toOffset: recordOffset)
                    guard try Self.read(file, count: expected.count) == expected else {
                        throw RouterFailure.conflict("索引写入读回不一致，原文件保留。")
                    }
                }
                let after = try FileManager.default.attributesOfItem(atPath: location.path)[.systemFileNumber] as? NSNumber
                guard identity == after else { throw RouterFailure.conflict("写入时索引被外部替换，保留事务以便补写。") }
            }
        }
    }

    func replace(_ oldLine: String, with newLine: String?, id: UUID, parent: URL,
                 beforeWrite: () throws -> Void = {}) throws {
        guard !Thread.isMainThread else { throw RouterFailure.io("索引修改必须在后台执行。") }
        try Self.queue.sync {
            try RouterIO.coordinated(parent.appendingPathComponent(RouterAccess.indexName), writing: true) { location in
                let fingerprint = try RouterIO.fingerprint(location)
                // ponytail: edits rewrite at most 64 MiB atomically; use a streaming replacement if a real index exceeds this.
                guard fingerprint.size <= 67_108_864 else { throw RouterFailure.conflict("索引超过 64 MiB，保留资产和索引，需另行处理。") }
                let data = try RouterIO.handle(RouterIO.open(location, flags: O_RDONLY)) { file in
                    var data = Data()
                    while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
                        guard data.count + chunk.count <= 67_108_864 else { throw RouterFailure.changed }
                        data.append(chunk)
                    }
                    return data
                }
                guard let text = String(data: data, encoding: .utf8), data.isEmpty || data.last == 10 else {
                    throw RouterFailure.conflict("索引存在无效编码或未完成的外部行，未改写。")
                }
                let marker = "<!-- OmniRouter:\(id.uuidString) -->"
                let rows = text.components(separatedBy: "\n")
                let owned = rows.indices.filter { rows[$0].contains(marker) }
                guard owned.count <= 1 else { throw RouterFailure.conflict("索引有重复操作标记，未改写。") }
                guard !owned.isEmpty else {
                    if newLine == nil { return } // Replaying a completed row removal.
                    throw RouterFailure.conflict("原索引记录缺失，保留修改意图与资产。")
                }
                guard let markerStart = text.range(of: marker)?.lowerBound else {
                    throw RouterFailure.conflict("索引操作标记位置异常，未改写。")
                }
                let start = text[..<markerStart].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let current = text[start...]
                if let newLine, current.hasPrefix(newLine) { return }
                guard current.hasPrefix(oldLine) else {
                    throw RouterFailure.conflict("这条索引已被外部编辑，未覆盖。")
                }
                var rewritten = text
                rewritten.replaceSubrange(start..<text.index(start, offsetBy: oldLine.count), with: newLine ?? "")
                let updated = Data(rewritten.utf8)
                try beforeWrite()
                guard try RouterIO.fingerprint(location) == fingerprint else {
                    throw RouterFailure.conflict("索引被外部替换或修改，未覆盖。")
                }
                try RouterIO.durableData(updated, to: location)
                guard try RouterIO.fingerprint(location).digest == RouterIO.digest(updated) else {
                    throw RouterFailure.conflict("索引修改读回不同，保留操作待重试。")
                }
            }
        }
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count, let chunk = try file.read(upToCount: count - result.count), !chunk.isEmpty {
            result.append(chunk)
        }
        return result
    }
}
