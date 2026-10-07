//
//  QuickShareService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Dynamic representation of a sharing provider discovered at runtime
struct QuickShareProvider: Identifiable, Hashable, Sendable {
    var id: String
    var imageData: Data?
    var supportsRawText: Bool
}

class QuickShareService: ObservableObject {
    static let shared = QuickShareService()
    
    @Published var availableProviders: [QuickShareProvider] = []
    @Published var isPickerOpen = false
    private var temporaryFileCleanupTasks: [URL: Task<Void, Never>] = [:]
    @MainActor private var isDiscoveringProviders = false

    // Sharing services may consume file URLs after `perform(withItems:)` returns.
    // Keep generated files briefly after the lifecycle callback, with a bounded
    // fallback in case a service never reports completion.
    private static let postShareCleanupDelay: Duration = .seconds(60)
    private static let maximumCleanupDelay: Duration = .seconds(600)
   
    // MARK: - Provider Discovery
    
    @MainActor
    func discoverAvailableProviders() async {
        guard availableProviders.isEmpty, !isDiscoveringProviders else { return }
        isDiscoveringProviders = true
        defer { isDiscoveringProviders = false }

        let finder = ShareServiceFinder()

        // Use simple test items without creating actual temp files
        // This avoids issues with the Share Sheet retaining references to deleted files
        let testItems: [Any] = [
            URL(string:"http://example.com") ?? URL(fileURLWithPath: "/"),
            "Test Text" as NSString
        ]

        let services = await finder.findApplicableServices(for: testItems)

        var providers: [QuickShareProvider] = []

        for svc in services {
            let title = svc.title
            // Some system sharing extensions expose an empty or stale asset
            // catalog. Reading `svc.image` can emit ImageIO/CoreUI faults even
            // though the service itself is usable, so the UI uses its stable
            // system fallback symbol instead.
            let imgData: Data? = nil
            let supportsRawText = svc.canPerform(withItems: ["Test Text"])
            let provider = QuickShareProvider(id: title, imageData: imgData, supportsRawText: supportsRawText)
            if !providers.contains(provider) {
                providers.append(provider)
            }
        }
        
        if let idx = providers.firstIndex(where: { $0.id == "AirDrop" }) {
            let ad = providers.remove(at: idx)
            providers.insert(ad, at: 0)
        }

        if !providers.contains(where: { $0.id == "系统分享菜单" }) {
            providers.append(QuickShareProvider(id: "系统分享菜单", imageData: nil, supportsRawText: true))
        }

        self.availableProviders = providers

    }
    
    // MARK: - File Picker
    @MainActor
    func showFilePicker(for provider: QuickShareProvider, from view: NSView?) async {
        guard !isPickerOpen else {
            print("⚠️ QuickShareService: File picker already open")
            return
        }

        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "选择要通过 \(provider.id) 分享的文件"
        panel.message = "请选择文件，然后通过 \(provider.id) 分享"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            defer {
                self?.isPickerOpen = false
                SharingStateManager.shared.endInteraction()
            }

            if response == .OK && !panel.urls.isEmpty {
                Task {
                    await self?.shareFilesOrText(panel.urls, using: provider, from: view)
                }
            }
        }

        let response = panel.runModal()
        completion(response)
    }
    
    // MARK: - Sharing
    @MainActor
    func shareFilesOrText(
        _ items: [Any],
        using provider: QuickShareProvider,
        from view: NSView?,
        temporaryFiles: [URL] = []
    ) async {
        let fileURLs = items.compactMap { $0 as? URL }.filter { $0.isFileURL }
        scheduleTemporaryFileCleanup(temporaryFiles, after: Self.maximumCleanupDelay)
        // Each concurrent share owns its own scoped URLs. Start access before
        // service discovery because extensions may inspect file metadata.
        let accessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }

        // NSSharingService instances are stateful because each operation assigns
        // its own delegate. Discover a fresh instance per invocation so
        // concurrent shares cannot overwrite one another's callbacks.
        let directService: NSSharingService?
        if provider.id == "系统分享菜单" {
            directService = nil
        } else {
            let services = await ShareServiceFinder().findApplicableServices(for: items)
            directService = services.first(where: { $0.title == provider.id && $0.canPerform(withItems: items) })
        }

        let presenter = [view, NSApp.keyWindow?.contentView, NSApp.mainWindow?.contentView]
            .compactMap { $0 }
            .first(where: { $0.window?.isVisible == true })
            ?? NSApp.windows.first(where: { $0.isVisible })?.contentView

        guard directService != nil || presenter != nil else {
            for url in accessingURLs {
                url.stopAccessingSecurityScopedResource()
            }
            scheduleTemporaryFileCleanup(temporaryFiles, after: Self.postShareCleanupDelay)
            NSLog("QuickShareService: no visible view was available to present the system share picker")
            return
        }

        // Setup lifecycle delegate to keep notch open during picker/service
        let delegate = SharingStateManager.shared.makeDelegate { [weak self] in
            for url in accessingURLs {
                url.stopAccessingSecurityScopedResource()
            }
            self?.scheduleTemporaryFileCleanup(temporaryFiles, after: Self.postShareCleanupDelay)
        }

        if let svc = directService {
            // For direct service path, explicitly mark service interaction start
            delegate.retain(service: svc)
            delegate.markServiceBegan()
            svc.delegate = delegate
            svc.perform(withItems: items)
        } else {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = delegate
            delegate.markPickerBegan()
            if let presenter {
                picker.show(relativeTo: .zero, of: presenter, preferredEdge: .minY)
            }
        }
    }

    @MainActor
    private func scheduleTemporaryFileCleanup(_ urls: [URL], after delay: Duration) {
        for url in Set(urls.map(\.standardizedFileURL)) {
            temporaryFileCleanupTasks[url]?.cancel()
            temporaryFileCleanupTasks[url] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }

                TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url)
                self?.temporaryFileCleanupTasks[url] = nil
            }
        }
    }
// MARK: - SharingServiceDelegate

private class SharingServiceDelegate: NSObject {}
    
    func shareDroppedFiles(_ providers: [NSItemProvider], using shareProvider: QuickShareProvider, from view: NSView?) async {
        var itemsToShare: [Any] = []
        var foundText: String?

        for provider in providers {
            if let webURL = await provider.extractURL() {
                itemsToShare.append(webURL)
            } else if foundText == nil, let text = await provider.extractText() {
                foundText = text
            } else if let itemFileURL = await provider.extractItem() {
                let resolvedURL = await resolveShelfItemBookmark(for: itemFileURL) ?? itemFileURL
                itemsToShare.append(resolvedURL)
            }
        }

        // If text was found, prioritize sharing it.
        if let text = foundText {
            if shareProvider.supportsRawText {
                await shareFilesOrText([text], using: shareProvider, from: view)
            } else {
                if let tempTextURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    await shareFilesOrText(
                        [tempTextURL],
                        using: shareProvider,
                        from: view,
                        temporaryFiles: [tempTextURL]
                    )
                } else {
                    await shareFilesOrText([text], using: shareProvider, from: view)
                }
            }
        } else if !itemsToShare.isEmpty {
            await shareFilesOrText(itemsToShare, using: shareProvider, from: view)
        }
    }

    private func resolveShelfItemBookmark(for fileURL: URL) async -> URL? {
        let items = await ShelfStateViewModel.shared.items

        for itm in items {
            if let resolved = await ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: itm) {
                if resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    return resolved
                }
            }
        }
        print("❌ Failed to resolve bookmark for shelf item")
        return nil
    }
}

// MARK: - App Storage Extension for Provider Selection

extension QuickShareProvider {
    static var defaultProvider: QuickShareProvider {
        let svc = QuickShareService.shared

        if let airdrop = svc.availableProviders.first(where: { $0.id == "AirDrop" }) {
            return airdrop
        }
        return svc.availableProviders.first ?? QuickShareProvider(id: "系统分享菜单", imageData: nil, supportsRawText: true)
    }
}
