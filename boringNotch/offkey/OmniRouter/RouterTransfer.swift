import AppKit
import Combine
import Darwin
import Foundation

struct RouterTransferSettings: Codable {
    var enabled = false
    var parent: RouterBookmark?
    var folderIconApplied: Bool?
}

struct RouterTransferItem: Identifiable {
    let id: UUID
    let url: URL
    let stamp: String
}

struct RouterTransferState {
    var enabled = false
    var location: URL?
    var items = [RouterTransferItem]()
    var message = "中转接收未启用。"
}

/// A process-owned watcher; no service, automatic import, or cloud-sync assertion.
final class RouterTransfer {
    static let shortcutInstructions = """
    1. 在 Mac 本页点「创建 iCloud 中转文件夹…」。系统窗口打开后选中 iCloud Drive，点「允许并创建」。App 会建好 OmniD-Transfer 手机收件箱并开启接收。
    2. 点本页「添加到快捷指令」，在系统窗口点「添加快捷指令」。Mac 的「快捷指令 → 设置 → 通用」开启 iCloud 同步；手机和平板使用同一 Apple 账号。
    3. 手机没出现指令时，点「发送到 iPhone / iPad」，通过隔空投送发到设备；接收后在「快捷指令」里点添加。
    4. 在手机 Safari、备忘录、照片或「文件」中点系统分享，选择「万有引力·记录」或「万有引力·文件」。保存位置选「iCloud Drive → OmniD-Transfer」，关闭覆盖已有文件。手机原件会保留。
    5. Mac 打开 OmniD-Pod 后，万有引力会提示待收；点「接收中转」，选分类，再点「记录 / 归档」。

    想以后一步保存：在手机「快捷指令」里长按对应指令 → 编辑，在「保存文件」动作关闭「询问保存位置」，点文件夹并选 iCloud Drive → OmniD-Transfer。每台设备分别选一次，保持关闭覆盖。
    手机「文件」里尚未出现收件箱时，先等 iCloud 同步；不要另建同名文件夹。尚未下载的文件先点下载。Mac 关闭时文件会留在收件箱，下次打开再接收。
    """
    let updates = PassthroughSubject<RouterTransferState, Never>()
    private let journal: RouterJournal
    private let files: OperationQueue
    private let queue = DispatchQueue(label: "OmniRouter.transfer", target: .global(qos: .utility))
    private let lock = NSLock()
    private var state = RouterTransferState()
    private var scope: RouterScope?
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var identity = ""
    private var seen = [String: Date]()
    private var ledger = [String: UUID]()
    private var generation = 0
    private var scheduled = false

    init(journal: RouterJournal, files: OperationQueue) { self.journal = journal; self.files = files }
    deinit { source?.cancel(); timer?.cancel() }

    static func location(in parent: URL) -> URL {
        parent.lastPathComponent == "OmniD-Transfer" ? parent : parent.appendingPathComponent("OmniD-Transfer", isDirectory: true)
    }

    func snapshot() -> RouterTransferState { lock.lock(); defer { lock.unlock() }; return state }

    func start() {
        queue.async {
            do { try self.activate(self.loadSettings()) }
            catch { self.fail(error) }
        }
    }

    static func validateCloudSelection(_ selection: URL, cloudRoot: URL) throws {
        let root = cloudRoot.standardizedFileURL
        let selected = selection.standardizedFileURL
        guard selected == root || selected == location(in: root) else {
            throw RouterFailure.invalid("请在系统窗口左侧点 iCloud Drive，再点「允许并创建」；也可以选其中已有的 OmniD-Transfer 文件夹。")
        }
    }

    func configure(parent: URL?, enabled: Bool, unbind: Bool = false,
                   cloudRoot: URL? = nil, iconURL: URL? = nil,
                   completion: @escaping (Result<RouterTransferSettings, Error>) -> Void) {
        let started = parent?.startAccessingSecurityScopedResource() ?? false
        queue.async {
            defer { if started { parent?.stopAccessingSecurityScopedResource() } }
            let result: Result<RouterTransferSettings, Error> = Result {
                var settings = try (unbind ? RouterTransferSettings() : self.loadSettings())
                if unbind { settings = RouterTransferSettings() }
                else {
                    if let parent {
                        if let cloudRoot { try Self.validateCloudSelection(parent.resolvingSymlinksInPath(), cloudRoot: cloudRoot) }
                        settings.parent = try RouterAccess.bookmark(parent, directory: true)
                        settings.folderIconApplied = nil
                    }
                    settings.enabled = enabled
                }
                if let bookmark = settings.parent, parent != nil || settings.enabled {
                    let grant = try RouterScope(bookmark: bookmark)
                    try withExtendedLifetime(grant) {
                        let root = try RouterAccess.directory(grant.url)
                        let folder = Self.location(in: root)
                        guard folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents == folder.standardizedFileURL.pathComponents else {
                            throw RouterFailure.conflict("中转目录是符号链接，请重新选择。")
                        }
                        if let archive = try self.journal.loadSettings()?.archive.location,
                           RouterAccess.inside(folder, RouterAccess.archiveLocation(in: archive)) {
                            throw RouterFailure.invalid("中转目录不能放在万物仓内部。")
                        }
                        try RouterIO.coordinated(root, writing: true) { _ in
                            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
                            catch let error as CocoaError where error.code == .fileWriteFileExists { }
                            _ = try Self.directoryIdentity(folder)
                            if let iconURL {
                                do {
                                    if let icon = NSImage(data: try Data(contentsOf: iconURL)) {
                                        settings.folderIconApplied = NSWorkspace.shared.setIcon(icon, forFile: folder.path, options: [])
                                    } else { settings.folderIconApplied = false }
                                } catch { settings.folderIconApplied = false }
                            }
                        }
                    }
                } else if settings.enabled { throw RouterFailure.access("请先点「创建 iCloud 中转文件夹…」，允许 App 使用手机收件箱。") }
                try self.save(settings, name: "transfer.json")
                try self.activate(settings)
                return settings
            }
            if case .failure(let error) = result { self.fail(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func refresh() { queue.async { self.scheduleScan() } }

    func receive(_ completion: @escaping (Result<[RouterInput], Error>) -> Void) {
        queue.async {
            guard let grant = self.scope else {
                DispatchQueue.main.async { completion(.failure(RouterFailure.access("中转未授权或已停用。"))) }; return
            }
            let pending = self.snapshot().items
            guard let location = self.snapshot().location else { return }
            let expected = self.identity
            self.files.addOperation {
                let result: Result<[RouterInput], Error> = Result {
                    try withExtendedLifetime(grant) {
                        guard try Self.directoryIdentity(location) == expected else { throw RouterFailure.changed }
                        return try pending.map { item in
                            try RouterIO.coordinated(item.url, writing: false) { file in
                                guard file.deletingLastPathComponent().standardizedFileURL == location.standardizedFileURL,
                                      try Self.stamp(file) == item.stamp else { throw RouterFailure.changed }
                                let fingerprint = try RouterIO.fingerprint(file)
                                guard try Self.stamp(file) == item.stamp else { throw RouterFailure.changed }
                                return RouterInput(id: item.id, value: .file(file, owned: false), title: file.lastPathComponent,
                                    bookmark: try RouterAccess.bookmark(file), fingerprint: fingerprint)
                            }
                        }
                    }
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func loadSettings() throws -> RouterTransferSettings {
        do { return try JSONDecoder().decode(RouterTransferSettings.self, from: Data(contentsOf: journal.directory.appendingPathComponent("transfer.json"))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return RouterTransferSettings() }
    }

    private func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: true)
        try RouterIO.coordinated(journal.directory, writing: true) { parent in
            try RouterIO.durableData(JSONEncoder().encode(value), to: parent.appendingPathComponent(name))
        }
    }

    private func activate(_ settings: RouterTransferSettings) throws {
        stop()
        guard settings.enabled, let bookmark = settings.parent else { emit(RouterTransferState(location: settings.parent?.location.map(Self.location))); return }
        let grant = try RouterScope(bookmark: bookmark)
        let location = Self.location(in: try RouterAccess.directory(grant.url))
        identity = try Self.directoryIdentity(location)
        do { ledger = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: journal.directory.appendingPathComponent("transfer-ledger.json"))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { ledger = [:] }
        let descriptor = Darwin.open(location.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
        let token = generation
        watcher.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if let flags = self.source?.data, !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                self.fail(RouterFailure.access("中转目录已移走或授权撤回，请重新选择。"))
            } else { self.scheduleScan() }
        }
        watcher.setCancelHandler { withExtendedLifetime(grant) { _ = Darwin.close(descriptor) } }
        scope = grant; source = watcher
        let periodic = DispatchSource.makeTimerSource(queue: queue)
        periodic.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        periodic.setEventHandler { [weak self] in self?.scheduleScan() }
        timer = periodic
        watcher.resume(); periodic.resume()
        emit(RouterTransferState(enabled: true, location: location, message: "中转接收已启用；等候文件稳定，不自动归档。"))
        scan()
    }

    private func stop() {
        generation += 1; scheduled = false
        source?.cancel(); source = nil
        timer?.cancel(); timer = nil
        scope = nil; seen = [:]
    }

    private func scheduleScan() {
        guard scope != nil, !scheduled else { return }
        scheduled = true
        let token = generation
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduled = false; self.scan()
        }
    }

    private func scan() {
        guard let grant = scope else { return }
        do {
            let location = Self.location(in: try RouterAccess.directory(grant.url))
            guard try Self.directoryIdentity(location) == identity else { throw RouterFailure.changed }
            var pending = [RouterTransferItem](), waiting = 0, settling = false, recent = [String: Date]()
            let previousLedger = ledger
            try RouterIO.coordinated(location, writing: false) { root in
                let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                // ponytail: flat 256-entry inbox; page the native list if real inboxes exceed this ceiling.
                for file in entries.prefix(256) {
                    let name = file.lastPathComponent
                    if file.pathExtension == "icloud" { waiting += 1; continue }
                    guard !name.hasPrefix("."), name != "Icon\r", !["tmp", "partial", "download"].contains(file.pathExtension.lowercased()) else { continue }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isAliasFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true, values.isAliasFile != true else { continue }
                    if values.isUbiquitousItem == true && ![URLUbiquitousItemDownloadingStatus.current, .downloaded].contains(values.ubiquitousItemDownloadingStatus ?? .notDownloaded) { waiting += 1; continue }
                    let stamp = try Self.stamp(file)
                    let key = RouterIO.digest(Data((file.absoluteString + "|" + stamp).utf8))
                    let first = seen[key] ?? Date()
                    recent[key] = first
                    guard Date().timeIntervalSince(first) >= 2 else { waiting += 1; settling = true; continue }
                    let id = ledger[key] ?? UUID()
                    // A persisted transaction owns all retries, including a retained original.
                    if try journal.load(id) != nil { continue }
                    ledger[key] = id
                    pending.append(RouterTransferItem(id: id, url: file, stamp: stamp))
                }
                if entries.count > 256 { waiting += entries.count - 256 }
            }
            if ledger != previousLedger { try save(ledger, name: "transfer-ledger.json") }
            seen = recent
            emit(RouterTransferState(enabled: true, location: location, items: pending,
                message: "中转待收 \(pending.count) 项；\(waiting) 项等待稳定、下载或超出 256 项显示上限。点击接收后选择分类归档，云端同步未确认。"))
            if settling { scheduleScan() }
        } catch { fail(error) }
    }

    private static func directoryIdentity(_ url: URL) throws -> String {
        guard url.resolvingSymlinksInPath().standardizedFileURL.pathComponents == url.standardizedFileURL.pathComponents,
              try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw RouterFailure.access("中转目录不可用或变成符号链接，请重新授权。")
        }
        let data = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = data[.systemNumber] as? NSNumber, let inode = data[.systemFileNumber] as? NSNumber else { throw RouterFailure.changed }
        return "\(device):\(inode)"
    }

    private static func stamp(_ url: URL) throws -> String {
        try RouterIO.regular(url)
        let data = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = data[.size] as? NSNumber, let date = data[.modificationDate] as? Date,
              let device = data[.systemNumber] as? NSNumber, let inode = data[.systemFileNumber] as? NSNumber else { throw RouterFailure.changed }
        return "\(device):\(inode):\(size):\(date.timeIntervalSince1970)"
    }

    private func fail(_ error: Error) { stop(); emit(RouterTransferState(message: "中转未授权或不可用：" + RouterFailure.message(for: error))) }
    private func emit(_ value: RouterTransferState) {
        lock.lock(); state = value; lock.unlock()
        DispatchQueue.main.async { self.updates.send(value) }
    }
}
