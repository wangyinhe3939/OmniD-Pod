import Darwin
import Foundation

final class RouterExecutor {
    private let journal: RouterJournal
    private let index: MarkdownIndexWriter
    private let check: (RouterCheckpoint) throws -> Void

    init(journal: RouterJournal, index: MarkdownIndexWriter = MarkdownIndexWriter(),
         check: @escaping (RouterCheckpoint) throws -> Void = { _ in }) {
        self.journal = journal
        self.index = index
        self.check = check
    }

    func run(_ request: RouterTransaction, renewedSettings: RouterSettings? = nil, publish: (RouterReceipt) -> Void) {
        var transaction = request
        func report() { publish(RouterReceipt(transaction)) }
        do {
            transaction = try journal.load(request.operationID) ?? request
            if transaction.phase == .undone { report(); return }
            if transaction.mutation != nil {
                if let settings = renewedSettings { transaction.settings = settings }
                resumeMutation(transaction, publish: publish)
                return
            }
            let wasComplete = transaction.phase == .complete
            if let settings = renewedSettings { transaction.settings = settings }
            try journal.save(transaction) // Intent is durable before touching the archive.
            try check(.intent)
            report()
            let archiveScope = try RouterScope(bookmark: transaction.settings.archive)
            let indexScope = try RouterScope(bookmark: transaction.settings.indexParent)
            var scopes = [archiveScope, indexScope]
            defer { withExtendedLifetime(scopes) {} }
            let root = try RouterAccess.archiveDirectory(archiveScope.url, existingDestination: transaction.destination)
            let parent = try RouterAccess.directory(indexScope.url)
            if let previous = transaction.indexParentLocation, previous != parent {
                throw RouterFailure.conflict("索引父目录改变，请重新授权原索引父目录后重试。")
            }
            transaction.indexParentLocation = parent
            let folder = root.appendingPathComponent(transaction.category.rawValue, isDirectory: true)
            try RouterIO.coordinated(root, writing: true) { _ in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      folder.resolvingSymlinksInPath().standardizedFileURL == folder.standardizedFileURL else {
                    throw RouterFailure.conflict("分类目录是符号链接，未归档。")
                }
            }
            var sourceURL: URL?
            var content: Data?
            var title: String
            switch transaction.payload {
            case .text(let text):
                guard !text.isEmpty else { throw RouterFailure.invalid("文字不能为空。") }
                content = Data(text.utf8)
                title = String(text.prefix(80))
            case .web(let original):
                guard let url = URL(string: original), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    throw RouterFailure.invalid("只接收有效的网页网址。")
                }
                content = Data((transaction.enrichment?.markdown(original: original) ?? original).utf8)
                title = original
            case .file(let bookmark):
                // Source access is needed for staging/cleanup, never to duplicate a committed archive.
                do {
                    let scope = try RouterScope(bookmark: bookmark)
                    scopes.append(scope)
                    sourceURL = scope.url
                } catch {
                    if transaction.archived == nil { throw error }
                }
                title = sourceURL?.lastPathComponent ?? transaction.destination?.lastPathComponent ?? "文件"
            }
            if transaction.displayName == nil { transaction.displayName = title }
            title = transaction.displayName ?? title
            if let source = sourceURL {
                let canonical = source.resolvingSymlinksInPath().standardizedFileURL
                guard !RouterAccess.inside(canonical, root),
                      canonical != parent.appendingPathComponent(RouterAccess.indexName).standardizedFileURL else {
                    throw RouterFailure.invalid("源文件已在归档目录内或就是索引，保留原文件。")
                }
            }
            if transaction.destination == nil {
                let extensionName = sourceURL?.pathExtension ?? "md"
                var stem = (sourceURL != nil ? transaction.enrichment?.title : nil) ?? sourceURL?.deletingPathExtension().lastPathComponent ?? "原文"
                if sourceURL != nil, transaction.enrichment != nil { stem = try RouterIntelligence.safeName(stem) }
                let suffix = "—" + transaction.operationID.uuidString + (extensionName.isEmpty ? "" : "." + extensionName)
                let budget = 255 - suffix.utf8.count
                guard budget > 0 else { throw RouterFailure.invalid("扩展名过长，保留原文件。") }
                while stem.utf8.count > budget { stem.removeLast() }
                let readable = stem + (extensionName.isEmpty ? "" : "." + extensionName)
                let filename = sourceURL != nil && transaction.enrichment != nil && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(readable).path)
                    ? readable : stem + suffix
                transaction.destination = folder.appendingPathComponent(filename)
                transaction.stage = folder.appendingPathComponent(".OmniRouter-" + transaction.operationID.uuidString + ".part")
                try journal.save(transaction)
            }
            guard let destination = transaction.destination, let stage = transaction.stage,
                  destination.deletingLastPathComponent() == folder, stage.deletingLastPathComponent() == folder else {
                throw RouterFailure.conflict("日志落点与授权目录不同，未修改文件。")
            }
            let committed = FileManager.default.fileExists(atPath: destination.path)
            if committed {
                let actual = try RouterIO.coordinated(destination, writing: false, RouterIO.fingerprint)
                guard let expected = transaction.archived, actual.hasSameContent(as: expected),
                      actual.permissions & 0o111 == expected.permissions & 0o111 else {
                    throw RouterFailure.conflict("目标已存在但未通过本操作校验，未覆盖。")
                }
            } else {
                transaction.phase = .staging
                try journal.save(transaction)
                report()
                if FileManager.default.fileExists(atPath: stage.path) {
                    let expected = transaction.archived ?? transaction.source
                    guard let expected = expected,
                          try RouterIO.coordinated(stage, writing: false, RouterIO.fingerprint).hasSameContent(as: expected) else {
                        throw RouterFailure.conflict("暂存文件未完成校验，保留暂存和原文件。")
                    }
                } else if let source = sourceURL {
                    try RouterIO.coordinated(source, writing: false) { location in
                        let fingerprint = try RouterIO.fingerprint(location)
                        if let previous = transaction.source, previous != fingerprint { throw RouterFailure.changed }
                        transaction.source = fingerprint
                        transaction.sourceLocation = location
                        try journal.save(transaction)
                        try check(.copy)
                        try RouterIO.coordinated(stage, writing: true) { target in
                            try FileManager.default.copyItem(at: location, to: target)
                        }
                        let staged = try RouterIO.fingerprint(stage)
                        guard staged.hasSameContent(as: fingerprint), try RouterIO.fingerprint(location) == fingerprint else {
                            throw RouterFailure.changed
                        }
                    }
                } else if let data = content {
                    try check(.copy)
                    try RouterIO.coordinated(stage, writing: true) { try RouterIO.writeExclusive(data, to: $0) }
                } else { throw RouterFailure.access("需要重新授权源文件；原文件保留。") }
                let staged = try RouterIO.coordinated(stage, writing: false, RouterIO.fingerprint)
                if let source = transaction.source {
                    guard staged.hasSameContent(as: source) else { throw RouterFailure.conflict("暂存内容与源快照不同，原文件保留。") }
                    guard staged.permissions & 0o111 == source.permissions & 0o111 else {
                        throw RouterFailure.access("目标未保留可执行属性；未修改属性，原文件保留。")
                    }
                } else if let data = content {
                    guard staged.size == UInt64(data.count), staged.digest == RouterIO.digest(data) else {
                        throw RouterFailure.conflict("原文暂存内容改变，保留输入。")
                    }
                }
                transaction.archived = staged
                try journal.save(transaction)
                try check(.staged)
                try RouterIO.commit(stage: stage, destination: destination, expected: staged)
                try check(.committed) // Crash after rename, before the next journal record.
            }
            transaction.phase = .fileCommitted
            transaction.message = "本地归档已校验；云端同步未确认。"
            if transaction.indexLine == nil {
                transaction.indexLine = MarkdownIndexWriter.line(id: transaction.operationID,
                    category: transaction.category, destination: destination, summary: title,
                    created: transaction.created, payload: transaction.payload, enrichment: transaction.enrichment)
            }
            try journal.save(transaction)
            report()
            guard let line = transaction.indexLine else { throw RouterFailure.conflict("日志缺少索引记录。") }
            do {
                try index.append(line, id: transaction.operationID, parent: parent, beforeWrite: { try self.check(.indexWrite) })
                try check(.indexed)
            } catch {
                transaction.phase = .indexPending
                throw error
            }
            transaction.phase = .indexCommitted
            try journal.save(transaction)
            report()
            if case .file = transaction.payload, !wasComplete {
                transaction.phase = .sourceCleanupPending
                try journal.save(transaction)
                try check(.cleanupPending)
                do {
                    guard let source = sourceURL, let expected = transaction.source else {
                        throw RouterFailure.access("源访问授权不可用，原文件待清理。")
                    }
                    guard source.standardizedFileURL == transaction.sourceLocation?.standardizedFileURL else {
                        throw RouterFailure.changed
                    }
                    try RouterIO.coordinated(source, writing: true) { location in
                            let current: RouterFingerprint
                            do { current = try RouterIO.fingerprint(location) }
                            catch let error as NSError where
                                (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) ||
                                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
                                // Explicit absence only; denied access never proves cleanup.
                                return
                            }
                            guard current == expected else { throw RouterFailure.changed }
                            let actualArchive = try RouterIO.coordinated(destination, writing: false, RouterIO.fingerprint)
                            guard let archived = transaction.archived, actualArchive.hasSameContent(as: archived),
                                  actualArchive.permissions & 0o111 == archived.permissions & 0o111 else {
                                throw RouterFailure.conflict("归档文件已变化，原文件保留。")
                            }
                            try check(.sourceCleanup)
                            // Reversible cleanup; a provider that refuses Trash leaves the source intact.
                            try RouterIO.trash(location)
                    }
                    try check(.cleaned)
                } catch {
                    transaction.phase = .sourceRetained
                    throw error
                }
            }
            transaction.phase = .complete
            transaction.message = "归档和索引均已完成；云端同步未确认。"
            if let note = transaction.intelligenceNote { transaction.message += " " + note }
            try journal.save(transaction)
            report()
        } catch {
            if transaction.phase != .indexPending && transaction.phase != .sourceRetained {
                switch error {
                case RouterFailure.access: transaction.phase = .accessRequired
                case RouterFailure.conflict, RouterFailure.changed: transaction.phase = .conflict
                default: transaction.phase = .failed
                }
            }
            transaction.message = RouterFailure.message(for: error)
            do { try journal.save(transaction) }
            catch { transaction.message += "；事务日志保存失败：" + RouterFailure.message(for: error) }
            report()
        }
    }
    func edit(_ request: RouterTransaction, title: String, category: RouterCategory, publish: (RouterReceipt) -> Void) {
        beginMutation(request, title: title, category: category, trash: false, publish: publish)
    }

    func undo(_ request: RouterTransaction, publish: (RouterReceipt) -> Void) {
        beginMutation(request, title: request.title, category: request.category, trash: true, publish: publish)
    }

    private func beginMutation(_ request: RouterTransaction, title: String, category: RouterCategory,
                               trash: Bool, publish: (RouterReceipt) -> Void) {
        var transaction = request
        do {
            transaction = try journal.load(request.operationID) ?? request
            if transaction.phase == .undone || transaction.mutation != nil { run(transaction, publish: publish); return }
            guard [.complete, .sourceRetained].contains(transaction.phase),
                  let from = transaction.destination, let oldLine = transaction.indexLine else {
                throw RouterFailure.invalid("请等待归档和索引提交完成，再修改或撤销。")
            }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameChanged = name != transaction.title
            guard trash || !nameChanged || (!name.isEmpty && ![".", ".."].contains(name)
                && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "/" })) else {
                throw RouterFailure.invalid("名称不能为空，也不能包含路径分隔符或控制字符。")
            }
            let rootScope = try RouterScope(bookmark: transaction.settings.archive)
            defer { withExtendedLifetime(rootScope) {} }
            let root = try RouterAccess.archiveDirectory(rootScope.url, existingDestination: transaction.destination)
            guard RouterAccess.inside(from, root), from.deletingLastPathComponent() == root.appendingPathComponent(transaction.category.rawValue, isDirectory: true) else {
                throw RouterFailure.conflict("原归档不在授权分类目录内，未修改。")
            }
            let suffix = "—" + transaction.operationID.uuidString + (from.pathExtension.isEmpty ? "" : "." + from.pathExtension)
            let stem = !from.pathExtension.isEmpty && name.hasSuffix("." + from.pathExtension)
                ? String(name.dropLast(from.pathExtension.count + 1)) : name
            guard trash || !nameChanged || stem.utf8.count + suffix.utf8.count <= 255 else { throw RouterFailure.invalid("名称过长，未修改。") }
            let filename = nameChanged ? stem + suffix : from.lastPathComponent
            let to = trash ? from : root.appendingPathComponent(category.rawValue, isDirectory: true).appendingPathComponent(filename)
            transaction.mutation = RouterHistoryMutation(kind: trash ? .trash : .edit, from: from, to: to,
                title: name, category: category, oldLine: oldLine,
                newLine: trash ? nil : MarkdownIndexWriter.line(id: transaction.operationID, category: category,
                    destination: to, summary: name, created: transaction.created, payload: transaction.payload, enrichment: transaction.enrichment),
                previousPhase: transaction.phase)
            transaction.phase = trash ? .undoPending : .editing
            try journal.save(transaction)
            try check(.historyIntent)
            publish(RouterReceipt(transaction))
            resumeMutation(transaction, publish: publish)
        } catch {
            transaction.message = "修改未完成：" + RouterFailure.message(for: error)
            publish(RouterReceipt(transaction))
        }
    }

    private func resumeMutation(_ request: RouterTransaction, publish: (RouterReceipt) -> Void) {
        var transaction = request
        do {
            guard var mutation = transaction.mutation, let expected = transaction.archived else {
                throw RouterFailure.conflict("缺少归档快照或修改意图，未修改资产。")
            }
            let archiveScope = try RouterScope(bookmark: transaction.settings.archive)
            let indexScope = try RouterScope(bookmark: transaction.settings.indexParent)
            defer { withExtendedLifetime((archiveScope, indexScope)) {} }
            let root = try RouterAccess.archiveDirectory(archiveScope.url, existingDestination: transaction.destination)
            let parent = try RouterAccess.directory(indexScope.url)
            guard transaction.indexParentLocation == parent, mutation.from == transaction.destination,
                  RouterAccess.inside(mutation.from, root), RouterAccess.inside(mutation.to, root),
                  mutation.from.resolvingSymlinksInPath().standardizedFileURL == mutation.from.standardizedFileURL,
                  mutation.to.resolvingSymlinksInPath().standardizedFileURL == mutation.to.standardizedFileURL else {
                throw RouterFailure.conflict("修改落点或索引授权路径已变化，保留资产。")
            }
            if mutation.kind == .edit {
                let folder = mutation.to.deletingLastPathComponent()
                try RouterIO.coordinated(root, writing: true) { _ in
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    guard folder == root.appendingPathComponent(mutation.category.rawValue, isDirectory: true),
                          folder.resolvingSymlinksInPath().standardizedFileURL == folder.standardizedFileURL else {
                        throw RouterFailure.conflict("分类目录改变，未移动资产。")
                    }
                }
                if mutation.from != mutation.to {
                    if let original = try RouterIO.fingerprintIfPresent(mutation.from) {
                        guard original == expected else { throw RouterFailure.changed }
                        try RouterIO.commit(stage: mutation.from, destination: mutation.to, expected: expected, allowedRoot: root)
                    } else {
                        guard try RouterIO.fingerprintIfPresent(mutation.to) == expected else {
                            throw RouterFailure.conflict("移动后的资产未通过日志快照校验，未覆盖。")
                        }
                    }
                }
                guard try RouterIO.fingerprintIfPresent(mutation.to) == expected else { throw RouterFailure.changed }
                try check(.historyMoved)
                try index.replace(mutation.oldLine, with: mutation.newLine, id: transaction.operationID, parent: parent,
                                  beforeWrite: { try self.check(.indexWrite) })
                try check(.historyIndexed)
                transaction.destination = mutation.to
                transaction.stage = folder.appendingPathComponent(".OmniRouter-" + transaction.operationID.uuidString + ".part")
                transaction.category = mutation.category
                transaction.displayName = mutation.title
                transaction.indexLine = mutation.newLine
                transaction.phase = mutation.previousPhase
                transaction.message = "名称、分类及索引已更新；云端同步未确认。"
            } else {
                if let actual = try RouterIO.fingerprintIfPresent(mutation.from) {
                    guard actual == expected else { throw RouterFailure.changed }
                    try index.replace(mutation.oldLine, with: nil, id: transaction.operationID, parent: parent,
                                      beforeWrite: { try self.check(.indexWrite) })
                    mutation.indexChanged = true
                    transaction.mutation = mutation
                    try journal.save(transaction)
                    try check(.historyIndexed)
                    transaction.trashedLocation = try RouterIO.coordinated(mutation.from, writing: true) { location in
                        guard try RouterIO.fingerprint(location) == expected else { throw RouterFailure.changed }
                        return try RouterIO.trash(location)
                    }
                    try journal.save(transaction)
                    try check(.historyTrashed)
                    transaction.message = "已撤销索引，归档资产已移入废纸篓。"
                } else {
                    guard mutation.indexChanged == true else { throw RouterFailure.conflict("归档资产已不在原落点，未静默撤销索引。") }
                    try index.replace(mutation.oldLine, with: nil, id: transaction.operationID, parent: parent)
                    transaction.message = transaction.trashedLocation == nil
                        ? "撤销索引已完成；归档已不在原落点，废纸篓位置未确认。"
                        : "已撤销索引，归档资产已移入废纸篓。"
                }
                transaction.phase = .undone
            }
            transaction.mutation = nil
            try journal.save(transaction)
        } catch {
            transaction.message = "修改待重试：" + RouterFailure.message(for: error)
            do { try journal.save(transaction) }
            catch { transaction.message += "；日志保存失败：" + RouterFailure.message(for: error) }
        }
        publish(RouterReceipt(transaction))
    }
}
