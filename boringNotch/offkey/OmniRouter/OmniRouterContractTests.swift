#if OMNIROUTER_CONTRACT_TESTS
import AppKit
import Darwin
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ value: Bool, _ message: String) throws {
    guard value else { throw CheckFailure(description: message) }
}

// Exercises the production receiver adapter asynchronously, without a drag window or real assets.
private final class FixturePromise: NSFilePromiseReceiver {
    private let fails: Bool
    private let outside: URL?
    init(fails: Bool, outside: URL? = nil) { self.fails = fails; self.outside = outside; super.init() }
    required init?(pasteboardPropertyList: Any, ofType type: NSPasteboard.PasteboardType) { return nil }
    override var fileTypes: [String] { ["public.plain-text"] }
    override var fileNames: [String] { ["承诺中文.txt"] }
    override func receivePromisedFiles(atDestination destination: URL, options: [AnyHashable: Any] = [:],
                                      operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        let failing = fails
        let foreign = outside
        operationQueue.addOperation {
            if let foreign = foreign { reader(foreign, nil); return }
            let file = destination.appendingPathComponent("承诺中文.txt")
            if failing { reader(file, NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED))); return }
            do { try RouterIO.writeExclusive(Data("promise original".utf8), to: file); reader(file, nil) }
            catch { reader(file, error) }
        }
    }
}

@MainActor private final class PromiseResults {
    var inputs = [RouterInput]()
    var failures = [String]()
    var count: Int { inputs.count + failures.count }
}

private struct RouterFixture {
    let directory: URL
    let archive: URL
    let indexParent: URL
    let journal: RouterJournal
    let settings: RouterSettings
    var indexURL: URL { indexParent.appendingPathComponent(RouterAccess.indexName) }

    init(_ name: String, root: URL) throws {
        directory = root.appendingPathComponent(name, isDirectory: true)
        archive = directory.appendingPathComponent("万物仓", isDirectory: true)
        indexParent = directory.appendingPathComponent("真实索引父目录", isDirectory: true)
        for url in [directory, archive, indexParent] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        journal = RouterJournal(directory: directory.appendingPathComponent("Journal", isDirectory: true))
        settings = RouterSettings(archive: try RouterAccess.bookmark(archive, directory: true, owned: true),
                                  indexParent: try RouterAccess.bookmark(indexParent, directory: true, owned: true))
    }

    func file(_ name: String = "中文 空格.txt", bytes: Data = Data("源文件\n".utf8)) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try RouterIO.writeExclusive(bytes, to: url)
        return url
    }

    func request(_ payload: RouterPayload, category: RouterCategory = .notes) -> RouterTransaction {
        RouterTransaction(operationID: UUID(), category: category, payload: payload, settings: settings, created: Date())
    }

    func run(_ request: RouterTransaction, check: @escaping (RouterCheckpoint) throws -> Void = { _ in }) throws -> RouterReceipt {
        var final: RouterReceipt?
        RouterExecutor(journal: journal, check: check).run(request) { final = $0 }
        guard let receipt = final else { throw CheckFailure(description: "没有事务结果") }
        return receipt
    }

    func indexed(_ id: UUID) throws -> Int {
        let text = try String(contentsOf: indexURL, encoding: .utf8)
        return text.components(separatedBy: "<!-- OmniRouter:\(id.uuidString) -->").count - 1
    }
}

@main private enum OmniRouterContractChecks {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { print("Usage: RouterContractChecks fixture-root"); exit(2) }
        do {
            try require(RouterFailure.message(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).contains("磁盘空间不足")
                && RouterFailure.message(for: CocoaError(.fileWriteNoPermission)).contains("没有访问权限")
                && RouterFailure.message(for: NSError(domain: NSPOSIXErrorDomain, code: Int.max)).contains("错误码")
                && !RouterFailure.message(for: NSError(domain: "Fixture", code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "English system error"])).contains("English"), "系统错误提示仍有英文残留")
            print("PASS Chinese-disk-full-permission-and-unknown-error-messages")
            let frame = NSRect(x: 0, y: 0, width: 300, height: 100)
            let editor = RouterTextView(frame: frame)
            editor.string = "中文输入 https://example.com"
            try require(editor.textStorage != nil && editor.string == "中文输入 https://example.com",
                        "NSTextView 指定初始化器未构建可编辑文本网络")
            print("PASS native-editor-frame-to-designated-dispatch-and-text-network")
            #if !OMNIROUTER_BACKEND_ONLY
            guard let factory = NSClassFromString("DDOmniRouterFactory") as? DDNativeSlotFactory.Type else {
                throw CheckFailure(description: "稳定类名/安全协议转换失败")
            }
            _ = factory.makeFactory()
            #endif
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let item = NSPasteboardItem()
            item.setString("https://example.com/中文", forType: .URL)
            item.setString("same item alternate representation", forType: .string)
            pasteboard.writeObjects([item])
            try require(RouterPasteboard.decode(pasteboard).inputs.count == 1, "同项 representation 重复")
            pasteboard.clearContents()
            pasteboard.setString("/not/an/access/grant", forType: .string)
            guard case .text = RouterPasteboard.decode(pasteboard).inputs.first?.value else {
                throw CheckFailure(description: "路径字符串被当作文件权限")
            }
            print("PASS representation-precedence, path-text (independent panel needs no notch interaction lease)")
        } catch { print("FAIL \(error)"); exit(1) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).absoluteURL.standardizedFileURL
        let results = PromiseResults()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.underlyingQueue = .global(qos: .utility)
        let finished: @MainActor @Sendable () -> Void = {
            guard results.count == 3 else { return }
            do { try require(results.inputs.count == 1 && results.failures.count == 2, "promise 成功/取消/越界回调不平衡") }
            catch { print("FAIL \(error)"); exit(1) }
            let received = results.inputs
            print("PASS asynchronous-promise-success-cancellation-and-path-boundary (injected receiver, native drag IPC untested)")
            DispatchQueue.global(qos: .utility).async {
                do { try backend(root, promised: received); print("PASS ALL backend contracts"); exit(0) }
                catch { print("FAIL \(error)"); exit(1) }
            }
        }
        RouterPromiseReceiving.receive([FixturePromise(fails: false), FixturePromise(fails: true),
            FixturePromise(fails: false, outside: root.appendingPathComponent("foreign.txt"))],
            to: root.appendingPathComponent("PromiseMaterialization", isDirectory: true), queue: queue,
            completion: { results.inputs += $0; finished() }, failed: { results.failures.append($0); finished() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if results.count < 3 { print("FAIL promise callback timeout"); exit(1) }
        }
        // AppKit views require the original main thread to keep running its event loop.
        // dispatchMain exits that thread and can flush its layer tree during thread teardown.
        RunLoop.main.run()
    }

    nonisolated private static func backend(_ root: URL, promised: [RouterInput]) throws {
        try RouterIntelligenceChecks.run(root)
        try RouterTransferChecks.run(root)
        let promise = try RouterFixture("异步承诺归档", root: root)
        for input in promised {
            guard case .file(let url, let owned) = input.value else { throw CheckFailure(description: "promise 类型错误") }
            let receipt = try promise.run(promise.request(.file(bookmark: try RouterAccess.bookmark(url, owned: owned))))
            try require(receipt.phase == .complete, "promise 物化后未归档：" + receipt.message)
        }
        print("PASS promised-file-production-transaction")
        let text = try RouterFixture("原文-索引缺失-重复", root: root)
        let original = "# 中文原文\n第二行 [方括号]\t<标签>"
        let request = text.request(.text(original))
        let first = try text.run(request)
        try require(first.phase == .complete, "原文归档失败：" + first.message)
        guard let destination = first.destination else { throw CheckFailure(description: "无归档落点") }
        try require(try String(contentsOf: destination, encoding: .utf8) == original, "原文被摘要替代")
        let duplicate = try text.run(request)
        try require(duplicate.phase == .complete && duplicate.destination == destination, "同 ID 重复提交改变落点")
        try require(try text.indexed(request.operationID) == 1, "同 ID 重复追加索引")
        print("PASS missing-index-create, Chinese-path, exact-text, duplicate-ID")
        let record = try String(contentsOf: text.indexURL, encoding: .utf8)
        let rows = record.split(separator: "\n")
        try require(rows.count == 4 && rows[0].hasPrefix("- [") && rows[0].contains("**#构想与纪要** ::")
            && rows[1].hasPrefix("  - 形式: 文字 Markdown") && rows[2].hasPrefix("  - 物理路径: `")
            && rows[3].hasPrefix("  - 来源/备注:") && !record.contains("第二行\n"), "四行契约或单行摘要不符")
        print("PASS timestamp-category-and-four-line-index-contract")

        let parentArchive = try RouterFixture("授权父目录归档", root: root)
        var parentRequest = parentArchive.request(.text("唯一万物仓"))
        let grantedParent = parentArchive.directory.appendingPathComponent("获授权云盘根", isDirectory: true)
        try FileManager.default.createDirectory(at: grantedParent, withIntermediateDirectories: false)
        parentRequest.settings.archive = try RouterAccess.bookmark(grantedParent, directory: true, owned: true)
        let parentResult = try parentArchive.run(parentRequest)
        let expectedStore = grantedParent.appendingPathComponent("万物仓", isDirectory: true)
        try require(parentResult.phase == .complete && parentResult.destination?.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == expectedStore.standardizedFileURL.path,
                    "授权父目录未使用万物仓或重复嵌套")
        try require(try parentArchive.run(parentRequest).phase == .complete, "新建万物仓的事务无法重播")
        let aliasArchive = try RouterFixture("万物仓符号链接拒绝", root: root)
        let outsideStore = aliasArchive.directory.appendingPathComponent("保持原样的目录", isDirectory: true)
        try FileManager.default.moveItem(at: aliasArchive.archive, to: outsideStore)
        try FileManager.default.createSymbolicLink(at: aliasArchive.archive, withDestinationURL: outsideStore)
        var aliasRequest = aliasArchive.request(.text("不准越界"))
        aliasRequest.settings.archive = try RouterAccess.bookmark(aliasArchive.directory, directory: true, owned: true)
        try require(try aliasArchive.run(aliasRequest).phase != .complete
            && !FileManager.default.fileExists(atPath: aliasArchive.indexURL.path)
            && !FileManager.default.fileExists(atPath: outsideStore.appendingPathComponent(aliasRequest.category.rawValue).path),
                    "万物仓符号链接越界写入")
        let oldArchive = try RouterFixture("旧落点保持兼容", root: root)
        var oldRequest = oldArchive.request(.text("旧资产原文"))
        let oldResult = try oldArchive.run(oldRequest)
        guard let oldRecord = try oldArchive.journal.load(oldRequest.operationID) else { throw CheckFailure(description: "旧落点无日志") }
        var legacyRecord = oldRecord
        legacyRecord.settings.archive = try RouterAccess.bookmark(oldArchive.directory, directory: true, owned: true)
        guard let previousAsset = oldResult.destination else { throw CheckFailure(description: "旧资产无落点") }
        let flatFolder = oldArchive.directory.appendingPathComponent(oldRecord.category.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: flatFolder, withIntermediateDirectories: false)
        let flatAsset = flatFolder.appendingPathComponent(previousAsset.lastPathComponent)
        try RouterIO.commit(stage: previousAsset, destination: flatAsset, expected: oldRecord.archived, allowedRoot: oldArchive.directory)
        legacyRecord.destination = flatAsset
        legacyRecord.stage = flatFolder.appendingPathComponent(".OmniRouter-" + oldRecord.operationID.uuidString + ".part")
        legacyRecord.indexLine = MarkdownIndexWriter.line(id: oldRecord.operationID, category: oldRecord.category,
            destination: flatAsset, summary: oldRecord.title)
        try Data((legacyRecord.indexLine ?? "").utf8).write(to: oldArchive.indexURL)
        try oldArchive.journal.save(legacyRecord)
        oldRequest.settings = legacyRecord.settings
        try require(try oldArchive.run(oldRequest).phase == .complete
            && oldArchive.journal.load(oldRequest.operationID)?.destination?.standardizedFileURL.path == flatAsset.standardizedFileURL.path,
                    "旧日志落点或单行恢复不兼容")
        RouterExecutor(journal: oldArchive.journal).edit(legacyRecord, title: "旧记录改名", category: .reference) { _ in }
        try require(try oldArchive.run(oldRequest).phase == .complete
            && String(contentsOf: oldArchive.indexURL, encoding: .utf8).split(separator: "\n").count == 4,
                    "旧单行改名未升级四行契约")
        print("PASS authorized-parent-single-store-and-legacy-row-replay")
        print("PASS archive-store-symlink-refusal-without-external-writes")

        let block = try RouterFixture("四行中断与外部冲突", root: root)
        let blockID = UUID()
        let blockDate = Date(timeIntervalSince1970: 1_791_264_000)
        let blockText = MarkdownIndexWriter.line(id: blockID, category: .visual,
            destination: block.archive.appendingPathComponent("图像 `` 中文.png"), summary: "双D金色Logo\n第二行",
            created: blockDate, payload: .file(bookmark: block.settings.archive))
        let blockBytes = Data(blockText.utf8)
        let marker = Data("<!-- OmniRouter:\(blockID.uuidString) -->".utf8)
        guard let markerRange = blockBytes.range(of: marker) else { throw CheckFailure(description: "缺事务标记") }
        let blockWriter = MarkdownIndexWriter()
        // Every byte boundary after the ownership marker includes split UTF-8 and complete-line interruptions.
        for cut in markerRange.upperBound..<blockBytes.count {
            try Data(blockBytes.prefix(cut)).write(to: block.indexURL, options: .atomic)
            try blockWriter.append(blockText, id: blockID, parent: block.indexParent)
            try blockWriter.append(blockText, id: blockID, parent: block.indexParent)
            try require(try Data(contentsOf: block.indexURL) == blockBytes, "四行中断恢复重复或丢失，字节：\(cut)")
        }
        try Data(blockBytes.prefix(12)).write(to: block.indexURL, options: .atomic)
        do { try blockWriter.append(blockText, id: blockID, parent: block.indexParent); throw CheckFailure(description: "不明归属的残缺标记被改写") }
        catch RouterFailure.conflict {}
        try require(try Data(contentsOf: block.indexURL) == Data(blockBytes.prefix(12)), "不明半行未保留")
        let external = "用户已有内容\n"
        let editedBlock = blockText.replacingOccurrences(of: "图片 PNG", with: "外部改动 PNG")
        try Data((external + editedBlock).utf8).write(to: block.indexURL, options: .atomic)
        do { try blockWriter.append(blockText, id: blockID, parent: block.indexParent); throw CheckFailure(description: "外部四行修改被覆盖") }
        catch RouterFailure.conflict {}
        do { try blockWriter.replace(blockText, with: nil, id: blockID, parent: block.indexParent); throw CheckFailure(description: "外部四行修改被撤销") }
        catch RouterFailure.conflict {}
        try require(try String(contentsOf: block.indexURL, encoding: .utf8) == external + editedBlock, "外部内容未保留")
        try Data((external + blockText).utf8).write(to: block.indexURL, options: .atomic)
        let revisedBlock = MarkdownIndexWriter.line(id: blockID, category: .reference,
            destination: block.archive.appendingPathComponent("新名称.png"), summary: "新名称", created: blockDate, payload: .text("原文"))
        try blockWriter.replace(blockText, with: revisedBlock, id: blockID, parent: block.indexParent)
        try blockWriter.replace(blockText, with: revisedBlock, id: blockID, parent: block.indexParent)
        try require(try String(contentsOf: block.indexURL, encoding: .utf8) == external + revisedBlock, "四行改名重播或邻接内容改变")
        try blockWriter.replace(revisedBlock, with: nil, id: blockID, parent: block.indexParent)
        try blockWriter.replace(revisedBlock, with: nil, id: blockID, parent: block.indexParent)
        try require(try String(contentsOf: block.indexURL, encoding: .utf8) == external, "撤销未精确移除整条四行记录")
        do {
            try blockWriter.append(blockText, id: blockID, parent: block.indexParent,
                beforeWrite: { try Data("外部替换保持原样\n".utf8).write(to: block.indexURL, options: .atomic) })
            throw CheckFailure(description: "追加时外部替换未识别")
        } catch RouterFailure.conflict {}
        try require(try String(contentsOf: block.indexURL, encoding: .utf8) == "外部替换保持原样\n", "追加覆盖外部替换")
        let started = Date()
        try blockWriter.append(blockText, id: blockID, parent: block.indexParent)
        print(String(format: "INDEX_APPEND_FIXTURE_MS %.3f (small local generated index; cloud latency untested)", Date().timeIntervalSince(started) * 1000))
        print("PASS all-owned-byte-cuts-UTF8-safe-repair-and-unknown-marker-conflict")
        print("PASS four-line-external-edit-protection-rename-undo-and-replay")
        print("PASS append-detects-external-replacement-and-retry-preserves-content")

        let url = try RouterFixture("URL原文", root: root)
        let urlOriginal = "https://example.com/中文?q=%5Braw%5D"
        let web = try url.run(url.request(.web(urlOriginal)))
        guard let webDestination = web.destination else { throw CheckFailure(description: "URL 没有落点") }
        try require(try String(contentsOf: webDestination, encoding: .utf8) == urlOriginal, "URL 原文变化")
        print("PASS exact-URL-without-fetch")

        let names = try RouterFixture("同名-无覆盖", root: root)
        let a = try names.run(names.request(.text("相同原文")))
        let b = try names.run(names.request(.text("相同原文")))
        try require(a.phase == .complete && b.phase == .complete && a.destination != b.destination, "同名资产被覆盖")
        let commitStage = try names.file("stage.txt")
        let existing = try names.file("exists.txt", bytes: Data("保护原件".utf8))
        do { try RouterIO.commit(stage: commitStage, destination: existing); throw CheckFailure(description: "无覆盖提交覆写了目标") }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {}
        try require(try String(contentsOf: existing, encoding: .utf8) == "保护原件", "同名目标内容变化")
        print("PASS distinct-operation-collision, exclusive-rename")

        for checkpoint in [RouterCheckpoint.intent, .staged, .committed, .indexed, .cleanupPending, .cleaned] {
            let fixture = try RouterFixture("恢复-" + checkpoint.rawValue, root: root)
            let source = try fixture.file()
            let transaction = fixture.request(.file(bookmark: try RouterAccess.bookmark(source, owned: true)))
            var injected = false
            let failed = try fixture.run(transaction) { point in
                if point == checkpoint && !injected { injected = true; throw CheckFailure(description: "注入 " + point.rawValue) }
            }
            try require(injected && failed.phase != .complete, "阶段注入未生效")
            if checkpoint != .cleaned { try require(FileManager.default.fileExists(atPath: source.path), "成功索引/清理前源文件丢失") }
            let recovered = try fixture.run(transaction)
            try require([RouterPhase.complete, .sourceRetained].contains(recovered.phase), "阶段恢复失败：\(checkpoint) \(recovered.message)")
            try require(try fixture.indexed(transaction.operationID) == 1, "恢复重复写索引")
            guard let archive = recovered.destination else { throw CheckFailure(description: "恢复无落点") }
            try require(try String(contentsOf: archive, encoding: .utf8) == "源文件\n", "恢复资产不完整")
            print("PASS durable-recovery-\(checkpoint.rawValue) -> \(recovered.phase.rawValue)")
        }

        let pending = try RouterFixture("索引失败只补索引", root: root)
        let source = try pending.file()
        let fileRequest = pending.request(.file(bookmark: try RouterAccess.bookmark(source, owned: true)))
        let failedIndex = try pending.run(fileRequest) { if $0 == .indexWrite { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) } }
        try require(failedIndex.phase == .indexPending && FileManager.default.fileExists(atPath: source.path), "索引失败源文件未保留")
        guard let committed = failedIndex.destination else { throw CheckFailure(description: "索引失败无落点") }
        let before = try RouterIO.fingerprint(committed)
        let retry = try pending.run(fileRequest)
        try require(retry.phase == .complete && retry.destination == committed && before == RouterIO.fingerprint(committed), "补索引时再次复制资产")
        print("PASS index-only-retry, source-preserved-until-index")

        let changed = try RouterFixture("源变化", root: root)
        let mutable = try changed.file()
        let changing = changed.request(.file(bookmark: try RouterAccess.bookmark(mutable, owned: true)))
        let retained = try changed.run(changing) { if $0 == .staged { try Data("新版本".utf8).write(to: mutable) } }
        try require(retained.phase == .sourceRetained && (try String(contentsOf: mutable, encoding: .utf8)) == "新版本", "变化的源被清理")
        print("PASS source-change-retains-new-version")

        for (name, code, point) in [("权限拒绝", EACCES, RouterCheckpoint.copy), ("磁盘满", ENOSPC, .copy), ("离线占位", ENETDOWN, .copy), ("源清理拒绝", EACCES, .sourceCleanup)] {
            let fixture = try RouterFixture(name, root: root)
            let input = try fixture.file()
            let transaction = fixture.request(.file(bookmark: try RouterAccess.bookmark(input, owned: true)))
            let failure = try fixture.run(transaction) { if $0 == point { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) } }
            try require(failure.phase != .complete && FileManager.default.fileExists(atPath: input.path), "故障丢失源文件：" + name)
            print("PASS injected-\(name) -> \(failure.phase.rawValue)")
        }

        let readonly = try RouterFixture("真实只读目录", root: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonly.archive.path)
        let readFailure = try readonly.run(readonly.request(.text("保留文字")))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonly.archive.path)
        try require(readFailure.phase != .complete, "只读目录错误报告成功")
        let invalid = RouterTransaction(operationID: UUID(), category: .notes, payload: .text("书签拒绝"),
            settings: RouterSettings(archive: RouterBookmark(data: Data([0]), securityScoped: true, location: nil), indexParent: readonly.settings.indexParent), created: Date())
        try require(try readonly.run(invalid).phase == .accessRequired, "无效书签未要求授权")
        print("PASS actual-read-only, invalid-bookmark")
        let authorization = try RouterFixture("配置安全降级", root: root)
        try authorization.journal.saveSettings(authorization.settings)
        try require(try authorization.journal.loadSettings() != nil, "有效配置未能读回")
        let broken = RouterBookmark(data: Data("invalid bookmark".utf8), securityScoped: true, location: nil)
        try authorization.journal.saveSettings(RouterSettings(archive: broken, indexParent: authorization.settings.indexParent))
        do { _ = try authorization.journal.loadSettings(); throw CheckFailure(description: "坏书签被视为已授权") }
        catch RouterFailure.access {}
        try authorization.journal.saveSettings(authorization.settings)
        try Data("broken journal".utf8).write(to: authorization.journal.directory.appendingPathComponent(UUID().uuidString + ".json"))
        do { _ = try authorization.journal.loadSettings(); throw CheckFailure(description: "损坏日志被视为已授权") }
        catch is DecodingError {}
        let corruptSettings = RouterJournal(directory: authorization.directory.appendingPathComponent("损坏设置"))
        try FileManager.default.createDirectory(at: corruptSettings.directory, withIntermediateDirectories: true)
        try Data("broken settings".utf8).write(to: corruptSettings.directory.appendingPathComponent("settings.json"))
        do { _ = try corruptSettings.loadSettings(); throw CheckFailure(description: "损坏设置被视为已授权") }
        catch is DecodingError {}
        print("PASS authorization-readback, corrupt-bookmark-settings-and-journal-safe-failure")

        let indexFixture = try RouterFixture("索引半行与替换", root: root)
        let id = UUID()
        let line = MarkdownIndexWriter.line(id: id, category: .reference, destination: indexFixture.archive.appendingPathComponent("中文.md"), summary: "摘要\n[内容]")
        let partial = Data(line.utf8).prefix(60)
        try RouterIO.writeExclusive(Data(partial), to: indexFixture.indexURL)
        let writer = MarkdownIndexWriter()
        try writer.append(line, id: id, parent: indexFixture.indexParent)
        try writer.append(line, id: id, parent: indexFixture.indexParent)
        try require(try String(contentsOf: indexFixture.indexURL, encoding: .utf8) == line, "半行修复丢失或重复")
        try Data("外部替换内容\n".utf8).write(to: indexFixture.indexURL, options: .atomic)
        try writer.append(line, id: id, parent: indexFixture.indexParent)
        try require(try String(contentsOf: indexFixture.indexURL, encoding: .utf8) == "外部替换内容\n" + line, "外部内容被覆盖")
        try Data("不完整外部尾部".utf8).write(to: indexFixture.indexURL, options: .atomic)
        do { try writer.append(line, id: id, parent: indexFixture.indexParent); throw CheckFailure(description: "未知半行被静默重写") }
        catch RouterFailure.conflict {}
        print("PASS partial-line-repair, external-replacement-preservation, unknown-tail-conflict")

        let parallel = try RouterFixture("多文件并发索引", root: root)
        let jobs = OmniRouterRuntime.shared.files
        try require(jobs.maxConcurrentOperationCount == 2, "文件并发上限不是 2")
        let group = DispatchGroup()
        let lock = NSLock()
        let parallelParent = parallel.indexParent
        var failures = [String]()
        for _ in 0..<8 {
            let id = UUID()
            let row = MarkdownIndexWriter.line(id: id, category: .visual, destination: parallel.archive.appendingPathComponent(id.uuidString),
                summary: "并发生成夹具", created: Date(), payload: .text("并发原文"))
            group.enter()
            jobs.addOperation {
                defer { group.leave() }
                do { try MarkdownIndexWriter().append(row, id: id, parent: parallelParent) }
                catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
            }
        }
        try require(group.wait(timeout: .now() + 5) == .success, "后台索引并发测试超时")
        try require(failures.isEmpty && (try String(contentsOf: parallel.indexURL, encoding: .utf8)).split(separator: "\n").count == 32, "并发四行索引丢失或交错")
        print("PASS eight-items-on-two-file-workers, single-serial-index-queue")

        let links = try RouterFixture("路径边界-可执行", root: root)
        let script = try links.file("脚本.sh", bytes: Data("#!/bin/sh\necho never-execute\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let executable = try links.run(links.request(.file(bookmark: try RouterAccess.bookmark(script, owned: true)), category: .tools))
        guard let scriptArchive = executable.destination else { throw CheckFailure(description: "脚本没有归档落点") }
        try require(executable.phase == .complete && (try RouterIO.fingerprint(scriptArchive)).permissions & 0o111 == 0o111, "执行属性未保留")
        let internalFile = links.archive.appendingPathComponent("已归档.txt")
        try RouterIO.writeExclusive(Data("existing".utf8), to: internalFile)
        let boundary = try links.run(links.request(.file(bookmark: try RouterAccess.bookmark(internalFile, owned: true))))
        try require(boundary.phase != .complete && FileManager.default.fileExists(atPath: internalFile.path), "归档内部源文件被接管")
        let symlink = links.directory.appendingPathComponent("软链接")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: internalFile)
        do { _ = try RouterAccess.bookmark(symlink, owned: true); throw CheckFailure(description: "文件软链接被接受") }
        catch RouterFailure.invalid {}
        let alias = links.directory.appendingPathComponent("目录链接")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: links.indexParent)
        let grant = try RouterScope(bookmark: RouterAccess.bookmark(alias, directory: true, owned: true))
        try require(grant.url.resolvingSymlinksInPath().standardizedFileURL.pathComponents == links.indexParent.standardizedFileURL.pathComponents,
                    "授权目录软链接未解析：\(grant.url) / \(links.indexParent)")
        print("PASS script-archive-without-execution, archive-source-boundary, file-symlink-rejection, directory-symlink")

        let altered = try RouterFixture("暂存变化", root: root)
        let originalFile = try altered.file()
        let altering = altered.request(.file(bookmark: try RouterAccess.bookmark(originalFile, owned: true)))
        let refused = try altered.run(altering) { point in
            if point == .staged, let stage = try altered.journal.load(altering.operationID)?.stage {
                try Data("外部暂存变化".utf8).write(to: stage)
            }
        }
        try require(refused.phase == .conflict && FileManager.default.fileExists(atPath: originalFile.path), "改变的暂存导致源丢失")
        let long = try RouterFixture("长中文文件名", root: root)
        let longFile = try long.file(String(repeating: "中", count: 80) + ".txt")
        let longResult = try long.run(long.request(.file(bookmark: try RouterAccess.bookmark(longFile, owned: true))))
        try require(longResult.phase == .complete && (longResult.destination?.lastPathComponent.utf8.count ?? 256) <= 255, "长中文名称未安全归档")
        print("PASS stage-change-refuses-commit, long-Unicode-name")

        let attributes = try RouterFixture("执行属性受限", root: root)
        let protectedScript = try attributes.file("保留脚本.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protectedScript.path)
        let protectedRequest = attributes.request(.file(bookmark: try RouterAccess.bookmark(protectedScript, owned: true)), category: .tools)
        let restricted = try attributes.run(protectedRequest) { point in
            if point == .staged, let stage = try attributes.journal.load(protectedRequest.operationID)?.stage {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
            }
        }
        try require(restricted.phase != .complete && FileManager.default.fileExists(atPath: protectedScript.path), "执行属性受限仍清理源")
        print("PASS executable-permission-loss-retains-source")

        let large = try RouterFixture("流式大文件", root: root)
        let largeSource = large.directory.appendingPathComponent("large.bin")
        try RouterIO.handle(RouterIO.open(largeSource, flags: O_WRONLY | O_CREAT | O_EXCL)) { file in
            let chunk = Data(repeating: 42, count: 65_536)
            for _ in 0..<256 { try file.write(contentsOf: chunk) }
            try file.synchronize()
        }
        let largeRequest = large.request(.file(bookmark: try RouterAccess.bookmark(largeSource, owned: true)))
        let largeResult = try large.run(largeRequest)
        guard let largeArchive = largeResult.destination else { throw CheckFailure(description: "大文件无落点") }
        try require(largeResult.phase == .complete && (try RouterIO.fingerprint(largeArchive)).size == 16_777_216, "大文件不完整")
        print("PASS streamed-16MiB-archive")

        let history = try RouterFixture("历史编辑与撤销", root: root)
        let historyRequest = history.request(.text("历史原文保持不变\n第二行"))
        _ = try history.run(historyRequest)
        guard let beforeEdit = try history.journal.load(historyRequest.operationID), let oldAsset = beforeEdit.destination else {
            throw CheckFailure(description: "无历史记录")
        }
        let executor = RouterExecutor(journal: history.journal)
        executor.edit(beforeEdit, title: "修改名称 [中文].md", category: .reference) { _ in }
        guard let edited = try history.journal.load(historyRequest.operationID), let editedAsset = edited.destination else {
            throw CheckFailure(description: "无编辑结果")
        }
        try require(edited.phase == .complete && edited.category == .reference && edited.title == "修改名称 [中文].md", "历史元数据未更新：" + edited.message)
        try require(editedAsset != oldAsset && !FileManager.default.fileExists(atPath: oldAsset.path), "分类未实际移动资产")
        try require(try String(contentsOf: editedAsset, encoding: .utf8) == "历史原文保持不变\n第二行", "编辑改写了原文")
        try require(try history.indexed(edited.operationID) == 1, "编辑重复索引")
        let link = RouterReceipt(edited).obsidianLink ?? ""
        try require(link.contains("\\[中文\\]") && link.contains(editedAsset.absoluteString), "Obsidian 链接未转义或落点错误")
        _ = try history.run(historyRequest)
        try require(try history.journal.load(historyRequest.operationID)?.destination == editedAsset, "旧请求重播撤销了改名")
        executor.undo(edited) { _ in }
        guard let undone = try history.journal.load(historyRequest.operationID) else { throw CheckFailure(description: "撤销缺日志") }
        try require(undone.phase == .undone && undone.trashedLocation != nil && !FileManager.default.fileExists(atPath: editedAsset.path), "撤销未移入废纸篓：" + undone.message)
        try require(try history.indexed(edited.operationID) == 0, "撤销未移除自己的索引")
        executor.undo(undone) { _ in }
        _ = try history.run(historyRequest)
        try require(try history.journal.load(historyRequest.operationID)?.phase == .undone, "重复提交复活撤销资产")
        print("PASS actual-rename-category-move, exact-original, Obsidian-link, undo-to-Trash, no-resurrection")

        for point in [RouterCheckpoint.historyIntent, .historyMoved, .historyIndexed] {
            let fixture = try RouterFixture("编辑恢复-" + point.rawValue, root: root)
            let request = fixture.request(.text("编辑恢复原文"))
            _ = try fixture.run(request)
            guard let current = try fixture.journal.load(request.operationID) else { throw CheckFailure(description: "缺编辑恢复日志") }
            RouterExecutor(journal: fixture.journal, check: { if $0 == point { throw CheckFailure(description: point.rawValue) } })
                .edit(current, title: "恢复名称", category: .visual) { _ in }
            let recovered = try fixture.run(request)
            try require(recovered.phase == .complete && recovered.title == "恢复名称", "编辑阶段恢复失败：" + recovered.message)
            try require(try fixture.indexed(request.operationID) == 1, "编辑阶段恢复重复索引")
            print("PASS edit-durable-recovery-" + point.rawValue)
        }
        for point in [RouterCheckpoint.historyIntent, .historyIndexed, .historyTrashed] {
            let fixture = try RouterFixture("撤销恢复-" + point.rawValue, root: root)
            let request = fixture.request(.text("撤销恢复原文"))
            _ = try fixture.run(request)
            guard let current = try fixture.journal.load(request.operationID) else { throw CheckFailure(description: "缺撤销恢复日志") }
            RouterExecutor(journal: fixture.journal, check: { if $0 == point { throw CheckFailure(description: point.rawValue) } })
                .undo(current) { _ in }
            let recovered = try fixture.run(request)
            try require(recovered.phase == .undone && (try fixture.indexed(request.operationID)) == 0, "撤销阶段恢复失败：" + recovered.message)
            print("PASS undo-durable-recovery-" + point.rawValue)
        }
        let protected = try RouterFixture("历史外部变化与索引失败", root: root)
        let historyProtectedRequest = protected.request(.text("保护原文"))
        _ = try protected.run(historyProtectedRequest)
        guard let protectedRecord = try protected.journal.load(historyProtectedRequest.operationID), let protectedAsset = protectedRecord.destination,
              let protectedLine = protectedRecord.indexLine else { throw CheckFailure(description: "缺保护夹具") }
        try Data("外部标题\n".utf8).write(to: protected.indexURL, options: .atomic)
        try MarkdownIndexWriter().append(protectedLine, id: protectedRecord.operationID, parent: protected.indexParent)
        RouterExecutor(journal: protected.journal, check: { if $0 == .indexWrite { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) } })
            .edit(protectedRecord, title: "索引重试", category: .tools) { _ in }
        let repaired = try protected.run(historyProtectedRequest)
        try require(repaired.phase == .complete && (try String(contentsOf: protected.indexURL, encoding: .utf8)).hasPrefix("外部标题\n"), "编辑索引重试覆盖外部内容")
        guard let revised = try protected.journal.load(historyProtectedRequest.operationID), let revisedAsset = revised.destination else { throw CheckFailure(description: "缺改名资产") }
        try Data("外部改写归档资产".utf8).write(to: revisedAsset)
        RouterExecutor(journal: protected.journal).undo(revised) { _ in }
        try require(FileManager.default.fileExists(atPath: revisedAsset.path) && (try protected.indexed(revised.operationID)) == 1, "撤销清理了外部改写资产")
        try require(!FileManager.default.fileExists(atPath: protectedAsset.path), "编辑未实际完成")
        print("PASS edit-index-only-retry-preserves-external-rows, changed-archive-refuses-undo")

        let replacement = try RouterFixture("编辑索引外部替换", root: root)
        let replacementID = UUID()
        let replacementLine = MarkdownIndexWriter.line(id: replacementID, category: .notes, destination: replacement.archive.appendingPathComponent("原文.md"), summary: "原文")
        try MarkdownIndexWriter().append(replacementLine, id: replacementID, parent: replacement.indexParent)
        do {
            try MarkdownIndexWriter().replace(replacementLine, with: nil, id: replacementID, parent: replacement.indexParent,
                beforeWrite: { try Data("外部替换\n".utf8).write(to: replacement.indexURL, options: .atomic) })
            throw CheckFailure(description: "编辑索引覆盖外部替换")
        } catch RouterFailure.conflict {}
        try require(try String(contentsOf: replacement.indexURL, encoding: .utf8) == "外部替换\n", "外部替换丢失")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(beforeEdit)) as? [String: Any] ?? [:]
        for key in ["displayName", "mutation", "trashedLocation"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(RouterTransaction.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(decoded.operationID == beforeEdit.operationID && !decoded.title.isEmpty, "第一阶段日志不兼容")
        print("PASS index-replacement-conflict, legacy-journal-readback")
        guard let webRecord = try url.journal.load(web.operationID) else { throw CheckFailure(description: "无 URL 历史") }
        let webExecutor = RouterExecutor(journal: url.journal)
        webExecutor.edit(webRecord, title: webRecord.title, category: .reference) { _ in }
        guard let webEdited = try url.journal.load(web.operationID) else { throw CheckFailure(description: "无 URL 分类结果") }
        try require(webEdited.phase == .complete && webEdited.category == .reference, "保持 URL 名称时无法修改分类")
        webExecutor.undo(webEdited) { _ in }
        try require(try url.journal.load(web.operationID)?.phase == .undone, "含路径分隔符的 URL 标题无法撤销")
        print("PASS URL-category-only-edit-and-undo")
    }
}
#endif
