import AppKit
import Combine
import Foundation

@MainActor
final class OffKeyNamingStore: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var directoryURL: URL?
    @Published private(set) var inspection: OffKeyFileInspection?
    @Published private(set) var scan: OffKeyNamingScan?
    @Published private(set) var locations: [OffKeyNamingLocation] = []
    @Published private(set) var isBusy = false
    @Published var prefix = "G"
    @Published var digits = 2
    @Published var shortName = "" {
        didSet { if shortName != oldValue { completedURL = nil } }
    }
    @Published private(set) var completedURL: URL?
    @Published var selectedNumber = 1
    @Published var allowDuplicate = false
    @Published var statusMessage = ""
    @Published var presentedError: String?

    private let locationStore: OffKeyNamingLocationStore
    private var securityScopedSourceURL: URL?
    private var securityScopedDirectoryURL: URL?
    private var scanGate = OffKeyScanRequestGate()
    private var pendingRescan = false

    init(locationStore: OffKeyNamingLocationStore = OffKeyNamingLocationStore()) {
        self.locationStore = locationStore
        locations = locationStore.locations()
    }

    deinit {
        securityScopedSourceURL?.stopAccessingSecurityScopedResource()
        securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
    }

    var rule: OffKeyNamingRule {
        OffKeyNamingRule(prefix: prefix, digits: digits)
    }

    var previewFilename: String? {
        guard let inspection else { return nil }
        return try? OffKeyNamingCore.filename(
            rule: rule,
            number: selectedNumber,
            shortName: shortName,
            fileExtension: inspection.fileExtension
        )
    }

    var canExecute: Bool {
        previewFilename != nil
            && sourceURL != nil
            && completedURL == nil
            && !isBusy
            && (scan?.duplicateURLs.isEmpty == true || allowDuplicate)
    }

    func chooseFile() {
        guard allowSelectionChange() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        acceptFile(url)
    }

    func acceptFile(_ url: URL) {
        guard allowSelectionChange() else { return }
        replaceSourceAccess(with: url)
        sourceURL = url
        completedURL = nil
        allowDuplicate = false
        if directoryURL == nil {
            inspection = nil
            scan = nil
            statusMessage = "已选择文件。请再选择一个目标文件夹；仅改名时请选择这个文件所在的文件夹。"
        } else {
            rescan()
        }
    }

    func chooseDirectory() {
        guard allowSelectionChange() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDirectory(url, restoreRule: true)
    }

    func selectLocation(_ location: OffKeyNamingLocation) {
        guard allowSelectionChange() else { return }
        do {
            let resolved = try locationStore.resolve(location)
            prefix = location.prefix
            digits = location.digitCount
            setDirectory(resolved.url, restoreRule: false)
            if resolved.stale {
                try locationStore.remember(url: resolved.url, rule: rule, pinned: location.isPinned)
                reloadLocations()
            }
        } catch {
            presentedError = "位置已失效，请重新选择文件夹。\n\(error.localizedDescription)"
        }
    }

    func toggleCurrentLocationPin() {
        guard allowSelectionChange() else { return }
        guard let directoryURL else { return }
        do {
            try locationStore.remember(
                url: directoryURL,
                rule: rule,
                pinned: !currentLocationIsPinned
            )
            reloadLocations()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func removeLocation(_ location: OffKeyNamingLocation) {
        guard allowSelectionChange() else { return }
        do {
            try locationStore.remove(id: location.id)
            reloadLocations()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    var currentLocationIsPinned: Bool {
        guard let path = directoryURL?.standardizedFileURL.path else { return false }
        return locations.first(where: { $0.id == path })?.isPinned == true
    }

    func ruleChanged() {
        completedURL = nil
        allowDuplicate = false
        guard !isBusy else {
            pendingRescan = true
            statusMessage = "当前操作完成后将按新规则重新扫描…"
            return
        }
        rescan()
    }

    func selectGap(_ number: Int) {
        guard !isBusy else { return }
        selectedNumber = number
    }

    func rescan() {
        guard directoryURL != nil else { return }
        guard !isBusy else {
            pendingRescan = true
            statusMessage = "当前操作完成后将重新扫描…"
            return
        }
        guard let generation = scanGate.request() else {
            statusMessage = "规则或位置已改变，正在按最新状态重新扫描…"
            return
        }
        startScan(generation: generation)
    }

    private func startScan(generation: Int) {
        guard let directoryURL, !isBusy else { return }
        let sourceURL = sourceURL
        let rule = rule
        isBusy = true
        inspection = nil
        scan = nil
        statusMessage = "正在扫描目录与核对文件…"

        Task.detached(priority: .userInitiated) {
            do {
                let inspection = try sourceURL.map { try OffKeyNamingCore.inspectFile(at: $0) }
                let scan = try OffKeyNamingCore.scanDirectory(
                    directoryURL,
                    rule: rule,
                    sourceURL: sourceURL
                )
                await MainActor.run {
                    if let nextGeneration = self.scanGate.finish(generation) {
                        self.isBusy = false
                        self.startScan(generation: nextGeneration)
                        return
                    }
                    self.inspection = inspection
                    self.scan = scan
                    self.selectedNumber = scan.next
                    self.isBusy = false
                    self.statusMessage = scan.duplicateURLs.isEmpty
                        ? "目录已核对"
                        : "发现完全相同文件：\n" + scan.duplicateURLs.map(\.path).joined(separator: "\n")
                    self.rememberCurrentLocation()
                    self.runPendingRescanIfNeeded()
                }
            } catch {
                await MainActor.run {
                    if let nextGeneration = self.scanGate.finish(generation) {
                        self.isBusy = false
                        self.startScan(generation: nextGeneration)
                        return
                    }
                    self.isBusy = false
                    self.statusMessage = error.localizedDescription
                    self.presentedError = error.localizedDescription
                    self.runPendingRescanIfNeeded()
                }
            }
        }
    }

    func execute(move: Bool) {
        guard canExecute, let sourceURL else { return }
        let destinationDirectory = move
            ? directoryURL
            : sourceURL.deletingLastPathComponent()
        guard let destinationDirectory else { return }

        if !move, directoryURL?.standardizedFileURL != destinationDirectory.standardizedFileURL {
            requestSourceDirectoryAuthorization(for: sourceURL)
            return
        }

        isBusy = true
        let rule = rule
        let number = selectedNumber
        let name = shortName
        let allowDuplicate = allowDuplicate
        Task.detached(priority: .userInitiated) {
            do {
                let result = try OffKeyNamingCore.execute(
                    source: sourceURL,
                    directory: destinationDirectory,
                    rule: rule,
                    number: number,
                    shortName: name,
                    allowDuplicate: allowDuplicate
                )
                await MainActor.run {
                    self.replaceSourceAccess(with: result)
                    self.sourceURL = result
                    self.completedURL = result
                    self.isBusy = false
                    self.scan = nil
                    self.statusMessage = "✓ 已保存\n\(result.path)"
                    self.pendingRescan = true
                    self.runPendingRescanIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = error.localizedDescription
                    self.presentedError = error.localizedDescription
                    self.runPendingRescanIfNeeded()
                }
            }
        }
    }

    func revealSource() {
        guard let sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
    }

    func revealFirstDuplicate() {
        guard let url = scan?.duplicateURLs.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func setDirectory(_ url: URL, restoreRule: Bool) {
        replaceDirectoryAccess(with: url)
        directoryURL = url
        allowDuplicate = false
        if restoreRule,
           let location = locations.first(where: { $0.id == url.standardizedFileURL.path }) {
            prefix = location.prefix
            digits = location.digitCount
        }
        rescan()
    }

    private func requestSourceDirectoryAuthorization(for sourceURL: URL) {
        let expectedDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = expectedDirectory
        panel.message = "仅改名需要你明确授权原文件所在的文件夹。"
        panel.prompt = "授权此文件夹"

        guard panel.runModal() == .OK, let selectedDirectory = panel.url else {
            statusMessage = "尚未授权原文件夹，未执行改名。"
            return
        }
        guard selectedDirectory.standardizedFileURL == expectedDirectory else {
            presentedError = "请选择原文件所在的文件夹：\n\(expectedDirectory.path)"
            return
        }

        setDirectory(selectedDirectory, restoreRule: true)
        statusMessage = "原文件夹已授权；正在重新扫描，请核对编号后再点一次。"
    }

    private func replaceSourceAccess(with url: URL) {
        guard securityScopedSourceURL?.standardizedFileURL != url.standardizedFileURL else { return }
        securityScopedSourceURL?.stopAccessingSecurityScopedResource()
        securityScopedSourceURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func replaceDirectoryAccess(with url: URL) {
        guard securityScopedDirectoryURL?.standardizedFileURL != url.standardizedFileURL else { return }
        securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
        securityScopedDirectoryURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func allowSelectionChange() -> Bool {
        guard !isBusy else {
            statusMessage = "请等待当前扫描或文件操作完成。"
            return false
        }
        return true
    }

    private func runPendingRescanIfNeeded() {
        guard pendingRescan else { return }
        pendingRescan = false
        rescan()
    }

    private func rememberCurrentLocation() {
        guard let directoryURL else { return }
        do {
            try locationStore.remember(
                url: directoryURL,
                rule: rule,
                pinned: currentLocationIsPinned
            )
            reloadLocations()
        } catch {
            statusMessage = "目录已核对；最近位置未保存：\(error.localizedDescription)"
        }
    }

    private func reloadLocations() {
        locations = locationStore.locations()
    }
}
