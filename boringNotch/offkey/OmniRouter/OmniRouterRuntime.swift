import Combine
import Foundation

enum RouterInputValue: Sendable {
    case text(String), web(String), file(URL, owned: Bool)
}

struct RouterInput: Identifiable, Sendable {
    let id: UUID
    let value: RouterInputValue
    let title: String
    let bookmark: RouterBookmark?
    let fingerprint: RouterFingerprint?
    init(id: UUID = UUID(), value: RouterInputValue, title: String,
         bookmark: RouterBookmark? = nil, fingerprint: RouterFingerprint? = nil) {
        self.id = id; self.value = value; self.title = title
        self.bookmark = bookmark; self.fingerprint = fingerprint
    }
}

final class OmniRouterRuntime {
    static let shared = OmniRouterRuntime()
    let receipts = PassthroughSubject<RouterReceipt, Never>()
    private let journal: RouterJournal
    private let intelligence: RouterIntelligence
    private let serviceKey: () throws -> String?
    let files: OperationQueue
    let transfer: RouterTransfer
    private let configuration = DispatchQueue(label: "OmniRouter.configuration", target: .global(qos: .utility))
    private let lock = NSLock()
    private var running = Set<UUID>()
    private var started = false
    private var latest = [UUID: RouterReceipt]()

    init(journal: RouterJournal = RouterJournal(), intelligence: RouterIntelligence = RouterIntelligence(),
         serviceKey: @escaping () throws -> String? = RouterAIKey.read) {
        self.journal = journal; self.intelligence = intelligence; self.serviceKey = serviceKey
        let queue = OperationQueue()
        queue.name = "OmniRouter.files"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        queue.underlyingQueue = .global(qos: .utility)
        files = queue
        transfer = RouterTransfer(journal: journal, files: queue)
    }

    func start() {
        lock.lock()
        let needed = !started
        started = true
        lock.unlock()
        guard needed else { return }
        transfer.start()
        configuration.async {
            do {
                for request in try self.journal.all() {
                    self.publish(RouterReceipt(request))
                    self.submit(request)
                }
            }
            catch { self.publish(RouterReceipt(operationID: UUID(), phase: .accessRequired,
                                               message: "未授权：恢复日志读取失败，请检查本地日志。" + RouterFailure.message(for: error), destination: nil)) }
        }
    }

    func snapshot() -> [RouterReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return Array(latest.values)
    }

    func settings(_ completion: @escaping (Result<RouterSettings?, Error>) -> Void) {
        configuration.async {
            let result: Result<RouterSettings?, Error>
            do { result = .success(try self.journal.loadSettings()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func configure(archive: URL?, indexParent: URL?, current: RouterSettings?,
                   completion: @escaping (Result<RouterSettings, Error>) -> Void) {
        // Keep the original grant alive while bookmark creation runs in the background.
        let urls = [archive, indexParent].compactMap { $0 }
        let starts = urls.map { $0.startAccessingSecurityScopedResource() }
        configuration.async {
            defer { for (url, started) in zip(urls, starts) where started { url.stopAccessingSecurityScopedResource() } }
            let result: Result<RouterSettings, Error> = Result {
                let archiveData = try archive.map { try RouterAccess.bookmark($0, directory: true) } ?? current?.archive
                let indexData = try indexParent.map { try RouterAccess.bookmark($0, directory: true) } ?? current?.indexParent
                guard let a = archiveData, let i = indexData else {
                    throw RouterFailure.access("还需选择另一个目录。")
                }
                let settings = RouterSettings(archive: a, indexParent: i)
                try self.journal.saveSettings(settings)
                return settings
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func accept(_ input: RouterInput, category: RouterCategory, settings: RouterSettings, intelligent: Bool = false) {
        // Admission covers bookmark preparation as well as the transaction itself.
        guard admit(input.id) else { return }
        let created = Date()
        let deadline = DispatchTime.now() + 3
        var received = RouterReceipt(operationID: input.id, phase: .queued, message: "已提交后台事务。", destination: nil)
        received.title = input.title; received.category = category; received.created = created
        publish(received)
        let grant: URL?
        if case .file(let url, _) = input.value { grant = url } else { grant = nil }
        let started = grant?.startAccessingSecurityScopedResource() ?? false
        files.addOperation {
            var pendingIntelligence = false
            defer {
                if started { grant?.stopAccessingSecurityScopedResource() }
                if !pendingIntelligence { self.finish(input.id) }
            }
            do {
                if let existing = try self.journal.load(input.id) {
                    RouterExecutor(journal: self.journal).run(existing, publish: self.publish)
                    return
                }
                let payload: RouterPayload
                switch input.value {
                case .text(let value): payload = .text(value)
                case .web(let value): payload = .web(value)
                case .file(let url, let owned): payload = .file(bookmark: try input.bookmark ?? RouterAccess.bookmark(url, owned: owned))
                }
                var request = RouterTransaction(operationID: input.id, category: category, payload: payload,
                                                settings: settings, created: created)
                request.source = input.fingerprint
                if intelligent {
                    // Restart can always finish this durable original without repeating an API call.
                    try self.journal.save(request)
                    pendingIntelligence = true
                    self.prepareIntelligence(request, deadline: deadline)
                } else { RouterExecutor(journal: self.journal).run(request, publish: self.publish) }
            } catch { self.publish(RouterReceipt(operationID: input.id, phase: .accessRequired,
                                                message: RouterFailure.message(for: error), destination: nil)) }
        }
    }

    func aiSettings(_ completion: @escaping (Result<(RouterAISettings, Bool), Error>) -> Void) {
        configuration.async {
            let result = Result { (try self.journal.aiSettings(), try RouterAIKey.read() != nil) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func configureAI(enabled: Bool, key: String, removeKey: Bool = false,
                     completion: @escaping (Result<(RouterAISettings, Bool), Error>) -> Void) {
        configuration.async {
            let result: Result<(RouterAISettings, Bool), Error> = Result {
                if !enabled { try self.journal.saveAISettings(RouterAISettings()) }
                if removeKey {
                    try self.journal.saveAISettings(RouterAISettings())
                    try RouterAIKey.remove()
                } else if !key.isEmpty { try RouterAIKey.save(key) }
                let available = try RouterAIKey.read() != nil
                guard !enabled || available else { throw RouterFailure.access("请先保存服务密钥，再启用智能识别。") }
                let settings = RouterAISettings(enabled: enabled && !removeKey)
                try self.journal.saveAISettings(settings)
                return (settings, available)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func prepareIntelligence(_ request: RouterTransaction, deadline: DispatchTime) {
        var received = RouterReceipt(operationID: request.operationID, phase: .queued,
            message: "正在尝试智能处理；超过 3 秒自动普通归档。", destination: nil)
        received.title = request.title; received.category = request.category; received.created = request.created
        publish(received)
        let job = RouterAIJob(deadline: deadline) { result, fingerprint in
            self.files.addOperation {
                defer { self.finish(request.operationID) }
                var prepared = request
                prepared.source = request.source ?? fingerprint
                var sourceChanged = false
                switch result {
                case .success(let enrichment):
                    prepared.enrichment = enrichment
                    prepared.displayName = enrichment.title
                    prepared.source = request.source ?? enrichment.fingerprint
                    if let expected = request.source, let actual = enrichment.fingerprint, expected != actual {
                        sourceChanged = true
                        prepared.phase = .conflict
                        prepared.message = RouterFailure.message(for: RouterFailure.changed)
                    }
                    prepared.intelligenceNote = "智能处理完成，请核对识别内容。"
                case .failure(let error):
                    prepared.intelligenceNote = RouterFailure.message(for: error) + " 原输入按普通流程归档。"
                    if case RouterFailure.changed = error {
                        sourceChanged = true
                        prepared.phase = .conflict
                        prepared.message = RouterFailure.message(for: error)
                    }
                }
                do {
                    try self.journal.save(prepared)
                    if sourceChanged { self.publish(RouterReceipt(prepared)) }
                    else { RouterExecutor(journal: self.journal).run(prepared, publish: self.publish) }
                } catch {
                    self.publish(RouterReceipt(operationID: request.operationID, phase: .failed,
                        message: "智能结果未能持久保存，原输入保留。" + RouterFailure.message(for: error), destination: nil))
                }
            }
        }
        configuration.async {
            guard job.active else { job.finish(.failure(RouterAIJob.timeout)); return }
            do {
                guard request.category != .tools else { throw RouterFailure.invalid("工具与脚本仅普通归档，不发送智能服务。") }
                guard try self.journal.aiSettings().enabled, let key = try self.serviceKey() else {
                    throw RouterFailure.access("智能识别未启用或密钥不可用，已回退普通归档。")
                }
                self.files.addOperation {
                    do { try self.intelligence.process(request.payload, key: key, job: job) }
                    catch { job.finish(.failure(error)) }
                }
            } catch { job.finish(.failure(error)) }
        }
    }

    func retry(_ id: UUID, settings: RouterSettings? = nil) {
        configuration.async {
            do {
                guard let request = try self.journal.load(id) else { return }
                self.submit(request, renewedSettings: settings)
            } catch { self.publish(RouterReceipt(operationID: id, phase: .failed, message: RouterFailure.message(for: error), destination: nil)) }
        }
    }

    func authorizeSource(_ id: UUID, file: URL) {
        guard admit(id) else { return }
        let started = file.startAccessingSecurityScopedResource()
        files.addOperation {
            defer { if started { file.stopAccessingSecurityScopedResource() }; self.finish(id) }
            do {
                guard var request = try self.journal.load(id), case .file(let old) = request.payload,
                      let expected = request.sourceLocation ?? old.location else {
                    throw RouterFailure.access("这项输入尚未提交事务，请重新选择文件后归档。")
                }
                let real = file.resolvingSymlinksInPath().standardizedFileURL
                guard real.pathComponents == expected.standardizedFileURL.pathComponents else {
                    throw RouterFailure.conflict("请选择这一操作原来的源文件；未更改归档落点。")
                }
                request.payload = .file(bookmark: try RouterAccess.bookmark(file))
                try self.journal.save(request)
                RouterExecutor(journal: self.journal).run(request, publish: self.publish)
            } catch { self.publish(RouterReceipt(operationID: id, phase: .sourceRetained,
                                                message: RouterFailure.message(for: error), destination: nil)) }
        }
    }

    func edit(_ id: UUID, title: String, category: RouterCategory) {
        mutate(id) { executor, request in executor.edit(request, title: title, category: category, publish: self.publish) }
    }

    func undo(_ id: UUID) {
        mutate(id) { executor, request in executor.undo(request, publish: self.publish) }
    }

    private func mutate(_ id: UUID, action: @escaping (RouterExecutor, RouterTransaction) -> Void) {
        guard admit(id) else { return }
        files.addOperation {
            defer { self.finish(id) }
            do {
                guard let request = try self.journal.load(id) else { throw RouterFailure.invalid("未找到这条归档的事务日志。") }
                action(RouterExecutor(journal: self.journal), request)
            } catch {
                self.publish(RouterReceipt(operationID: id, phase: .failed, message: RouterFailure.message(for: error), destination: nil))
            }
        }
    }

    private func submit(_ request: RouterTransaction, renewedSettings: RouterSettings? = nil) {
        guard admit(request.operationID) else { return }
        files.addOperation {
            defer { self.finish(request.operationID) }
            RouterExecutor(journal: self.journal).run(request, renewedSettings: renewedSettings, publish: self.publish)
        }
    }

    private func admit(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.insert(id).inserted
    }

    private func finish(_ id: UUID) {
        lock.lock()
        running.remove(id)
        lock.unlock()
    }

    private func publish(_ incoming: RouterReceipt) {
        var receipt = incoming
        lock.lock()
        if let previous = latest[receipt.operationID] {
            receipt.title = receipt.title ?? previous.title
            receipt.category = receipt.category ?? previous.category
            receipt.created = receipt.created ?? previous.created
        }
        latest[receipt.operationID] = receipt
        lock.unlock()
        let update = receipt
        transfer.refresh()
        DispatchQueue.main.async { self.receipts.send(update) }
    }
}
