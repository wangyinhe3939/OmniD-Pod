#if OMNIROUTER_CONTRACT_TESTS
import AppKit
import Darwin
import Foundation

enum RouterTransferChecks {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw RouterFailure.invalid("中转夹具：" + message) }
    }
    private static func wait(_ message: String, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(8)
        while !condition() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        try check(condition(), message)
    }
    @discardableResult private static func configure(_ watcher: RouterTransfer, enabled: Bool, unbind: Bool = false,
                                                     parent: URL? = nil, cloudRoot: URL? = nil,
                                                     iconURL: URL? = nil) throws -> RouterTransferSettings {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<RouterTransferSettings, Error>?
        watcher.configure(parent: parent, enabled: enabled, unbind: unbind, cloudRoot: cloudRoot, iconURL: iconURL) {
            outcome = $0; done.signal()
        }
        try check(done.wait(timeout: .now() + 8) == .success, "设置没有完成")
        guard let outcome else { throw RouterFailure.invalid("中转设置无结果") }
        return try outcome.get()
    }
    private static func receive(_ watcher: RouterTransfer) throws -> [RouterInput] {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<[RouterInput], Error>?
        watcher.receive { outcome = $0; done.signal() }
        try check(done.wait(timeout: .now() + 8) == .success, "接收没有完成")
        guard let outcome else { throw RouterFailure.invalid("中转接收无结果") }
        return try outcome.get()
    }
    static func run(_ root: URL) throws {
        let folder = root.appendingPathComponent("三端中转", isDirectory: true)
        let cloud = folder.appendingPathComponent("生成云盘", isDirectory: true)
        let archive = folder.appendingPathComponent("万物仓", isDirectory: true)
        let index = folder.appendingPathComponent("真实索引", isDirectory: true)
        let journal = RouterJournal(directory: folder.appendingPathComponent("Journal", isDirectory: true))
        for file in [cloud, archive, index, journal.directory] { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
        let settings = RouterSettings(archive: try RouterAccess.bookmark(archive, directory: true, owned: true),
                                      indexParent: try RouterAccess.bookmark(index, directory: true, owned: true))
        try journal.saveSettings(settings)
        func saveTransfer(_ value: RouterTransferSettings) throws {
            try RouterIO.durableData(JSONEncoder().encode(value), to: journal.directory.appendingPathComponent("transfer.json"))
        }
        let runtime = OmniRouterRuntime(journal: journal)
        runtime.start()
        try check(!runtime.transfer.snapshot().enabled, "旧配置默认启用监听")
        try saveTransfer(RouterTransferSettings(parent: try RouterAccess.bookmark(cloud, directory: true, owned: true)))
        try RouterTransfer.validateCloudSelection(cloud, cloudRoot: cloud)
        try RouterTransfer.validateCloudSelection(RouterTransfer.location(in: cloud), cloudRoot: cloud)
        for wrong in [archive, cloud.appendingPathComponent("选错的子文件夹"), folder.appendingPathComponent("同名假云盘/OmniD-Transfer")] {
            do {
                try RouterTransfer.validateCloudSelection(wrong, cloudRoot: cloud)
                throw RouterFailure.io("允许了错误的手机收件箱位置")
            } catch RouterFailure.invalid { }
        }
        let failedIcon = folder.appendingPathComponent("没有这个图标.icns")
        let connected = try configure(runtime.transfer, enabled: true, parent: cloud, cloudRoot: cloud, iconURL: failedIcon)
        try check(connected.enabled && connected.folderIconApplied == false, "图标失败阻断了手机收件箱，或错误报告图标成功")
        let inbox = RouterTransfer.location(in: cloud)
        try check(FileManager.default.fileExists(atPath: inbox.path), "未在授权父目录创建中转")
        let iconFile = folder.appendingPathComponent("生成图标.tiff")
        guard let icon = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: nil)?.tiffRepresentation else {
            throw RouterFailure.invalid("无法生成图标夹具")
        }
        try icon.write(to: iconFile)
        let withIcon = try configure(runtime.transfer, enabled: true, parent: cloud, cloudRoot: cloud, iconURL: iconFile)
        try check(withIcon.folderIconApplied == true, "原生文件夹图标未设置成功")
        let source = inbox.appendingPathComponent("原有手机资料.txt")
        try RouterIO.writeExclusive(Data("保留原有文件".utf8), to: source)
        try configure(runtime.transfer, enabled: true, parent: inbox, cloudRoot: cloud)
        try check(try String(contentsOf: source, encoding: .utf8) == "保留原有文件", "重新连接覆盖了原有手机资料")
        try check(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("OmniD-Transfer").path), "重复创建嵌套收件箱")
        try FileManager.default.moveItem(at: source, to: folder.appendingPathComponent("验证后保留的手机资料.txt"))
        print("PASS transfer-one-click-creation-cloud-location-validation-reconnect-preserves-files-and-icon-failure-fallback")
        for name in ["手机文字.md", "手机图片.png", "脚本.py", "待补索引.txt"] {
            try RouterIO.writeExclusive(Data((name + "\nhttps://example.com/原始网址").utf8), to: inbox.appendingPathComponent(name))
        }
        let foreign = folder.appendingPathComponent("外部原件.txt")
        try RouterIO.writeExclusive(Data("不可接管".utf8), to: foreign)
        try FileManager.default.createSymbolicLink(at: inbox.appendingPathComponent("越界链接.txt"), withDestinationURL: foreign)
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("目录"), withIntermediateDirectories: false)
        for name in ["未完成.partial", ".隐藏.txt", ".云占位.icloud"] {
            try RouterIO.writeExclusive(Data("保留".utf8), to: inbox.appendingPathComponent(name))
        }
        try check(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Icon\r").path), "原生图标元数据缺失")
        try wait("未稳定接收四个文件") { runtime.transfer.snapshot().items.count == 4 }
        try check(try journal.all().isEmpty, "监听擅自提交事务")
        try check(runtime.transfer.snapshot().message.contains("等待"), "离线与未完成状态未显示")
        let received = try receive(runtime.transfer)
        let repeated = try receive(runtime.transfer)
        try check(Set(received.map(\.id)) == Set(repeated.map(\.id)), "重复接收更换操作 ID")
        try check(received.allSatisfy { $0.bookmark != nil && $0.fingerprint != nil }, "路径冒充授权或遗漏源快照")
        print("PASS transfer-authorized-creation-stability-no-auto-import-hidden-symlink-placeholder-and-stable-admission")

        guard let text = received.first(where: { $0.title == "手机文字.md" }),
              let pending = received.first(where: { $0.title == "待补索引.txt" }),
              let changed = received.first(where: { $0.title == "脚本.py" }),
              let image = received.first(where: { $0.title == "手机图片.png" }) else { throw RouterFailure.invalid("中转接收缺项") }
        runtime.accept(text, category: .notes, settings: settings)
        runtime.accept(text, category: .notes, settings: settings)
        try wait("文本未归档") { runtime.snapshot().contains { $0.operationID == text.id && $0.phase == .complete } }
        guard let completed = try journal.load(text.id), let destination = completed.destination else { throw RouterFailure.invalid("中转归档无目标") }
        try check(try String(contentsOf: destination, encoding: .utf8).contains("原始网址"), "原文丢失")
        let indexURL = index.appendingPathComponent(RouterAccess.indexName)
        try check(try String(contentsOf: indexURL, encoding: .utf8).components(separatedBy: "<!-- OmniRouter:\(text.id.uuidString) -->").count == 2, "中转重复索引")
        try check(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent(text.title).path), "成功后未清理中转")
        print("PASS transfer-production-local-archive-four-line-index-duplicate-submit-and-post-index-cleanup")

        guard let bookmark = pending.bookmark else { throw RouterFailure.invalid("缺少授权") }
        var request = RouterTransaction(operationID: pending.id, category: .reference, payload: .file(bookmark: bookmark), settings: settings, created: Date())
        request.source = pending.fingerprint
        RouterExecutor(journal: journal, check: { if $0 == .indexWrite { throw RouterFailure.io("注入索引失败") } }).run(request) { _ in }
        try check(try journal.load(pending.id)?.phase == .indexPending, "未保留索引失败事务")
        runtime.transfer.refresh()
        try wait("已提交操作仍待收") { !runtime.transfer.snapshot().items.contains { $0.id == pending.id || $0.id == text.id } }
        let originalCount = try FileManager.default.contentsOfDirectory(at: archive.appendingPathComponent("灵感参考"), includingPropertiesForKeys: nil).count
        runtime.retry(pending.id)
        try wait("未补写索引") { runtime.snapshot().contains { $0.operationID == pending.id && $0.phase == .complete } }
        try check(try FileManager.default.contentsOfDirectory(at: archive.appendingPathComponent("灵感参考"), includingPropertiesForKeys: nil).count == originalCount, "补索引重复归档")
        print("PASS transfer-index-failure-retains-source-ledger-suppresses-reimport-index-only-retry")

        try Data("源发生变化".utf8).write(to: inbox.appendingPathComponent(changed.title))
        runtime.accept(changed, category: .tools, settings: settings)
        try wait("源变化未拒绝") { runtime.snapshot().contains { $0.operationID == changed.id && $0.phase == .conflict } }
        try check(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(changed.title).path), "变化的脚本被清理")
        print("PASS transfer-received-snapshot-changed-source-preserved-and-script-never-executed")

        try configure(runtime.transfer, enabled: false)
        try check(!runtime.transfer.snapshot().enabled, "停用未解除监听")
        try saveTransfer(RouterTransferSettings(enabled: true, parent: try RouterAccess.bookmark(cloud, directory: true, owned: true)))
        let restarted = OmniRouterRuntime(journal: journal)
        restarted.start()
        try wait("重启未保留稳定 ID") { restarted.transfer.snapshot().items.contains { $0.id == image.id } }
        try check(!restarted.transfer.snapshot().items.contains { $0.id == pending.id || $0.id == text.id }, "重启重复接管已提交事务")
        try configure(restarted.transfer, enabled: false)
        let ledgerURL = journal.directory.appendingPathComponent("transfer-ledger.json")
        let validLedger = try Data(contentsOf: ledgerURL)
        try RouterIO.durableData(Data("{损坏".utf8), to: ledgerURL)
        do { try configure(restarted.transfer, enabled: true); throw RouterFailure.invalid("损坏账本被忽略") }
        catch { try check(!restarted.transfer.snapshot().enabled, "损坏账本继续运行") }
        try check(try Data(contentsOf: ledgerURL) == Data("{损坏".utf8), "损坏账本被清空")
        try RouterIO.durableData(validLedger, to: ledgerURL)
        try configure(restarted.transfer, enabled: true)
        try FileManager.default.moveItem(at: inbox, to: cloud.appendingPathComponent("移走中转"))
        try wait("移走目录未停止") { !restarted.transfer.snapshot().enabled }
        try configure(restarted.transfer, enabled: false, unbind: true)
        try check(restarted.transfer.snapshot().location == nil && FileManager.default.fileExists(atPath: foreign.path), "解绑改动原件")
        try check(try Data(contentsOf: ledgerURL) == validLedger, "解绑丢失恢复账本")
        print("PASS transfer-restart-persistent-ID-disable-corrupt-ledger-directory-removal-and-unbind-preserve-data")
        let invalid = RouterTransferSettings(enabled: true, parent: RouterBookmark(data: Data([0]), securityScoped: true, location: cloud))
        try saveTransfer(invalid)
        let denied = OmniRouterRuntime(journal: journal)
        denied.start()
        try wait("无效书签未降级") { denied.transfer.snapshot().message.contains("不可用") }
        try check(!denied.transfer.snapshot().enabled && RouterTransfer.shortcutInstructions.contains("关闭覆盖"), "无效授权或快捷指令覆盖约束缺失")
        print("PASS transfer-invalid-bookmark-safe-Chinese-fallback-and-native-shortcut-copy-contract")
    }
}
#endif
