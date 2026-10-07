#if OMNIROUTER_CONTRACT_TESTS
import Foundation

private final class IntelligenceReply: URLProtocol {
    enum Mode { case page, image, malformed, blocked, denied, offline, slow }
    static let lock = NSLock()
    private static var mode: Mode = .page
    private static var requests = [URLRequest]()
    private let state = NSLock()
    private var stopped = false

    static func reset(_ value: Mode) { lock.lock(); mode = value; requests = []; lock.unlock() }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while body.count <= 1_048_576 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock()
        let mode = Self.mode
        Self.requests.append(captured)
        Self.lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (mode == .slow ? 3.25 : 0.01)) { [self] in
            state.lock(); let cancelled = stopped; state.unlock()
            guard !cancelled else { return }
            do {
                if mode == .offline { throw URLError(.notConnectedToInternet) }
                guard let url = request.url, let response = HTTPURLResponse(url: url,
                    statusCode: mode == .denied ? 403 : 200, httpVersion: "HTTP/1.1", headerFields: [:]) else {
                    throw RouterFailure.invalid("夹具响应不可构造。")
                }
                let document: [String: Any] = ["title": mode == .image ? "双D复古金色Logo" : "网页要点",
                    "points": mode == .image ? [] : ["第一句核心观点。", "第二句核心观点。", "第三句核心观点。"]]
                let json = try JSONSerialization.data(withJSONObject: document)
                var candidate: [String: Any] = ["finishReason": "STOP", "content": ["parts": [["text": String(decoding: json, as: UTF8.self)]]]]
                if mode != .blocked {
                    candidate["urlContextMetadata"] = ["urlMetadata": [["retrievedUrl": "https://example.com/article",
                        "urlRetrievalStatus": "URL_RETRIEVAL_STATUS_SUCCESS"]]]
                }
                let bytes = mode == .malformed ? Data("{broken".utf8) : try JSONSerialization.data(withJSONObject: ["candidates": [candidate]])
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: bytes)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { state.lock(); stopped = true; state.unlock() }
}

enum RouterIntelligenceChecks {
    private static let key = "fixture-key-no-real-service"
    private static let original = "https://example.com/article"

    private static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw RouterFailure.invalid("智能夹具：" + message) }
    }
    private static func client() -> RouterIntelligence {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntelligenceReply.self]
        return RouterIntelligence(configuration: configuration)
    }

    private static func response(_ payload: RouterPayload, mode: IntelligenceReply.Mode,
                                 using client: RouterIntelligence) throws -> Result<RouterEnrichment, Error> {
        try check(!Thread.isMainThread, "不得在主线程等待夹具")
        IntelligenceReply.reset(mode)
        let finished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var outcome: Result<RouterEnrichment, Error>?
        var count = 0
        let started = Date()
        let job = RouterAIJob(deadline: .now() + 3) { result, _ in
            resultLock.lock(); outcome = result; count += 1; resultLock.unlock()
            finished.signal()
        }
        do { try client.process(payload, key: key, job: job) }
        catch { job.finish(.failure(error)) }
        try check(finished.wait(timeout: .now() + 4) == .success, "回调超时")
        if mode == .slow {
            let elapsed = Date().timeIntervalSince(started)
            try check((2.9...3.5).contains(elapsed), "没有遵守 3 秒硬超时")
        }
        job.finish(.failure(RouterFailure.io("迟到响应")))
        Thread.sleep(forTimeInterval: 0.06)
        resultLock.lock(); let final = outcome; let callbacks = count; resultLock.unlock()
        try check(callbacks == 1, "完成或取消重复回调")
        guard let final else { throw RouterFailure.invalid("智能夹具没有结果") }
        return final
    }

    static func run(_ root: URL) throws {
        let client = client()
        let enrichment = try response(.web(original), mode: .page, using: client).get()
        try check(enrichment.points.count == 3, "不是三个观点")
        guard let request = IntelligenceReply.captured().first, let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw RouterFailure.invalid("未捕获原生请求")
        }
        try check(request.value(forHTTPHeaderField: "x-goog-api-key") == key &&
            request.url?.host == "generativelanguage.googleapis.com" && request.url?.query == nil &&
            !String(decoding: body, as: UTF8.self).contains(key) && object["tools"] != nil, "密钥或工具请求契约错误")
        print("PASS AI-native-request-key-header-three-points-and-public-retrieval-metadata")
        for mode in [IntelligenceReply.Mode.malformed, .blocked, .denied, .offline, .slow] {
            if case .success = try response(.web(original), mode: mode, using: client) {
                throw RouterFailure.invalid("错误服务响应被当作成功")
            }
        }
        print("PASS AI-malformed-unretrieved-403-offline-three-second-timeout-single-callback")
        for value in ["http://127.0.0.1/a", "http://localhost/a", "https://host.local/a", "file:///etc/passwd", "https://user:pass@example.com/a"] {
            do { _ = try RouterIntelligence.publicURL(value); throw RouterFailure.io("不安全网址被接收") }
            catch RouterFailure.invalid { }
        }
        for value in ["../图片", "中文/逃逸", "EnglishOnly", "中文\n换行", ".中文", "中文:路径"] {
            do { _ = try RouterIntelligence.safeName(value); throw RouterFailure.io("不安全名称被接收") }
            catch RouterFailure.invalid { }
        }
        try check(!RouterAIKey.valid("bad\r\nheader") && RouterAIKey.valid(key), "密钥验证失败")
        print("PASS AI-public-URL-path-name-and-key-trust-boundaries")

        let folder = root.appendingPathComponent("智能闭环", isDirectory: true)
        let archive = folder.appendingPathComponent("万物仓", isDirectory: true)
        let parent = folder.appendingPathComponent("索引", isDirectory: true)
        for path in [archive, parent] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let settings = RouterSettings(archive: try RouterAccess.bookmark(archive, directory: true, owned: true),
            indexParent: try RouterAccess.bookmark(parent, directory: true, owned: true))
        let journal = RouterJournal(directory: folder.appendingPathComponent("日志", isDirectory: true))
        var web = RouterTransaction(operationID: UUID(), category: .reference, payload: .web(original), settings: settings, created: Date())
        web.enrichment = enrichment; web.displayName = enrichment.title
        var final: RouterReceipt?
        RouterExecutor(journal: journal).run(web) { final = $0 }
        guard let destination = final?.destination else { throw RouterFailure.invalid("智能网址无落点") }
        let document = try String(contentsOf: destination, encoding: .utf8)
        try check(final?.phase == .complete && document.hasPrefix(original) && enrichment.points.allSatisfy(document.contains), "原链接或提炼未归档")
        let indexURL = parent.appendingPathComponent(RouterAccess.indexName)
        let block = try String(contentsOf: indexURL, encoding: .utf8)
        try check(block.split(separator: "\n").count == 4 && enrichment.points.allSatisfy(block.contains), "索引格式或观点缺失")
        RouterExecutor(journal: journal).run(web) { final = $0 }
        try check(try String(contentsOf: indexURL, encoding: .utf8) == block, "智能记录重复追加")
        RouterExecutor(journal: journal).edit(web, title: "新标题", category: .notes) { final = $0 }
        try check(final?.phase == .complete && (try String(contentsOf: indexURL, encoding: .utf8)).contains(enrichment.points[0]), "编辑丢失智能元数据")
        RouterExecutor(journal: journal).undo(web) { final = $0 }
        try check(final?.phase == .undone && (try String(contentsOf: indexURL, encoding: .utf8)).isEmpty, "智能记录撤销不完整")
        print("PASS AI-URL-original-plus-summary-four-line-index-idempotent-edit-and-undo")

        guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aSAAAAABJRU5ErkJggg==") else {
            throw RouterFailure.invalid("生成图片夹具失败")
        }
        let source = folder.appendingPathComponent("hash-image.png")
        try RouterIO.writeExclusive(png, to: source)
        let bookmark = try RouterAccess.bookmark(source, owned: true)
        let imageResult = try response(.file(bookmark: bookmark), mode: .image, using: client).get()
        try check(imageResult.fingerprint != nil, "图片没有源快照")
        let oversized = folder.appendingPathComponent("oversized.png")
        try RouterIO.handle(RouterIO.open(oversized, flags: O_WRONLY | O_CREAT | O_EXCL)) { try $0.truncate(atOffset: 8_388_609) }
        do {
            _ = try RouterIntelligence.image(RouterAccess.bookmark(oversized, owned: true))
            throw RouterFailure.io("超大图片没有回退")
        } catch RouterFailure.invalid { }
        var image = RouterTransaction(operationID: UUID(), category: .visual, payload: .file(bookmark: bookmark), settings: settings, created: Date())
        image.enrichment = imageResult; image.source = imageResult.fingerprint; image.displayName = imageResult.title
        RouterExecutor(journal: journal, check: { if $0 == .indexWrite { throw RouterFailure.io("注入索引失败") } }).run(image) { final = $0 }
        try check(final?.phase == .indexPending && FileManager.default.fileExists(atPath: source.path), "索引失败清理了源")
        RouterExecutor(journal: journal).run(image) { final = $0 }
        guard let named = final?.destination else { throw RouterFailure.invalid("图片无落点") }
        try check(final?.phase == .complete && named.lastPathComponent == "双D复古金色Logo.png" &&
            (try Data(contentsOf: named)) == png, "中文名、扩展名或原始图片字节被改变")
        let another = folder.appendingPathComponent("another-hash.png")
        try RouterIO.writeExclusive(png, to: another)
        var collision = RouterTransaction(operationID: UUID(), category: .visual,
            payload: .file(bookmark: try RouterAccess.bookmark(another, owned: true)), settings: settings, created: Date())
        collision.enrichment = imageResult; collision.source = try RouterIO.fingerprint(another); collision.displayName = imageResult.title
        RouterExecutor(journal: journal).run(collision) { final = $0 }
        try check(final?.phase == .complete && final?.destination != named && (try Data(contentsOf: named)) == png, "同名覆盖旧图")
        let changed = folder.appendingPathComponent("changed.png")
        try RouterIO.writeExclusive(png, to: changed)
        var changing = RouterTransaction(operationID: UUID(), category: .visual,
            payload: .file(bookmark: try RouterAccess.bookmark(changed, owned: true)), settings: settings, created: Date())
        changing.enrichment = imageResult; changing.source = try RouterIO.fingerprint(changed); changing.displayName = imageResult.title
        try (png + Data([0])).write(to: changed)
        RouterExecutor(journal: journal).run(changing) { final = $0 }
        try check(final?.phase == .conflict && FileManager.default.fileExists(atPath: changed.path), "图片变化后清理了源")
        print("PASS AI-image-Chinese-name-original-bytes-index-retry-collision-and-source-change")

        for (label, enabled, selectedKey, mode, intelligent, category) in [
            ("disabled", false, Optional(key), IntelligenceReply.Mode.page, true, RouterCategory.reference),
            ("no-key", true, nil, .page, true, .reference),
            ("denied-key", true, nil, .page, true, .reference),
            ("corrupt-settings", true, Optional(key), .page, true, .reference),
            ("offline", true, Optional(key), .offline, true, .reference),
            ("timeout", true, Optional(key), .slow, true, .reference),
            ("normal", true, Optional(key), .page, false, .reference),
            ("tools", true, Optional(key), .page, true, .tools),
            ("success", true, Optional(key), .page, true, .reference)] {
            IntelligenceReply.reset(mode)
            let local = RouterJournal(directory: folder.appendingPathComponent(label, isDirectory: true))
            try check(try !local.aiSettings().enabled, "新配置没有默认停用")
            try local.saveAISettings(RouterAISettings(enabled: enabled))
            if label == "corrupt-settings" { try Data("{broken".utf8).write(to: local.directory.appendingPathComponent("intelligence.json")) }
            let runtime = OmniRouterRuntime(journal: local, intelligence: client, serviceKey: {
                if label == "denied-key" { throw RouterFailure.access("注入钥匙串权限拒绝") }
                return selectedKey
            })
            let input = RouterInput(value: .web(original), title: original)
            runtime.accept(input, category: category, settings: settings, intelligent: intelligent)
            runtime.accept(input, category: category, settings: settings, intelligent: intelligent)
            let limit = Date().addingTimeInterval(5)
            while Date() < limit && runtime.snapshot().first?.phase != .complete { Thread.sleep(forTimeInterval: 0.01) }
            guard let result = try local.load(input.id), let file = result.destination else { throw RouterFailure.invalid("运行时无事务") }
            let bytes = try String(contentsOf: file, encoding: .utf8)
            try check(result.phase == .complete && bytes.hasPrefix(original), "运行时没有完成或丢失原文")
            if label == "success" { try check(result.enrichment != nil, "成功结果未持久化") }
            else { try check(result.enrichment == nil && bytes == original, "降级没有保持原文") }
            if ["disabled", "no-key", "denied-key", "corrupt-settings", "normal", "tools"].contains(label) {
                try check(IntelligenceReply.captured().isEmpty, "关闭、未授权、普通记录或工具类别仍联网")
            }
        }
        print("PASS AI-production-runtime-admission-durable-success-disabled-keyless-denied-corrupt-offline-timeout-normal-tools-fallback")
        IntelligenceReply.reset(.slow)
        let delayedJournal = RouterJournal(directory: folder.appendingPathComponent("等待中源变化", isDirectory: true))
        try delayedJournal.saveAISettings(RouterAISettings(enabled: true))
        let delayedSource = folder.appendingPathComponent("delayed.png")
        try RouterIO.writeExclusive(png, to: delayedSource)
        let delayedRuntime = OmniRouterRuntime(journal: delayedJournal, intelligence: client, serviceKey: { key })
        let delayedInput = RouterInput(value: .file(delayedSource, owned: true), title: "delayed.png")
        delayedRuntime.accept(delayedInput, category: .visual, settings: settings, intelligent: true)
        let startedLimit = Date().addingTimeInterval(2)
        while Date() < startedLimit && IntelligenceReply.captured().isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        try check(!IntelligenceReply.captured().isEmpty, "图片服务请求未开始")
        try (png + Data([0])).write(to: delayedSource)
        let delayedLimit = Date().addingTimeInterval(4)
        while Date() < delayedLimit && delayedRuntime.snapshot().first?.phase != .conflict { Thread.sleep(forTimeInterval: 0.01) }
        try check(delayedRuntime.snapshot().first?.phase == .conflict && FileManager.default.fileExists(atPath: delayedSource.path), "超时回退丢失源快照")
        print("PASS AI-timeout-retains-prepared-image-snapshot-and-changed-source")
        for prompt in RouterPrompt.allCases { try check(!prompt.text.isEmpty, "提示词为空") }
        print("PASS AI-three-prompt-capsules-and-legacy-settings-default-disabled")
    }
}
#endif
