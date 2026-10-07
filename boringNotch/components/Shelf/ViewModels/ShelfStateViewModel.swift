//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem]
    @Published private(set) var persistenceIssue: ShelfPersistenceIssue?

    @Published var isLoading: Bool = false

    var isEmpty: Bool { items.isEmpty }
    var canModifyItems: Bool { didCompleteInitialLoad }
    var canRetryPersistence: Bool {
        persistenceIssue?.kind != .corruptedData
    }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?
    private var didCompleteInitialLoad: Bool

    private init() {
        switch ShelfPersistenceService.shared.load() {
        case .loaded(let loadedItems):
            items = loadedItems
            persistenceIssue = nil
            didCompleteInitialLoad = true
        case .failed(let issue):
            items = []
            persistenceIssue = issue
            didCompleteInitialLoad = false
        }
    }


    func add(_ newItems: [ShelfItem]) {
        guard didCompleteInitialLoad, !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
            }
        }
        replaceItems(merged)
    }

    func remove(_ item: ShelfItem) {
        guard didCompleteInitialLoad else { return }
        let updatedItems = items.filter { $0.id != item.id }
        if replaceItems(updatedItems) {
            item.cleanupStoredData()
        }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard didCompleteInitialLoad else { return }
        var updatedItems = items
        guard let idx = updatedItems.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = updatedItems[idx].kind {
            updatedItems[idx].kind = .file(bookmark: bookmark)
            replaceItems(updatedItems)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            var updatedItems = self.items
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = updatedItems.firstIndex(where: { $0.id == itemID }),
                   case .file = updatedItems[idx].kind {
                    updatedItems[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            self.pendingBookmarkUpdates.removeAll()
            self.replaceItems(updatedItems)
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard didCompleteInitialLoad, !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        guard didCompleteInitialLoad else { return }
        Task { [weak self] in
            guard let self else { return }
            let snapshot = self.items
            var invalidItems: [ShelfItem] = []
            for item in snapshot {
                switch item.kind {
                case .file(let data):
                    let bookmark = Bookmark(data: data)
                    if !(await bookmark.validate()) {
                        invalidItems.append(item)
                    }
                default:
                    break
                }
            }
            await MainActor.run {
                let invalidSnapshotByID = Dictionary(uniqueKeysWithValues: invalidItems.map { ($0.id, $0) })
                let itemsToRemove = self.items.filter { current in
                    guard let invalidSnapshot = invalidSnapshotByID[current.id] else { return false }
                    return current == invalidSnapshot
                }
                guard !itemsToRemove.isEmpty else { return }

                let removalIDs = Set(itemsToRemove.map(\.id))
                let updatedItems = self.items.filter { !removalIDs.contains($0.id) }
                if self.replaceItems(updatedItems) {
                    itemsToRemove.forEach { $0.cleanupStoredData() }
                }
            }
        }
    }

    func retryPersistence() {
        guard canRetryPersistence else { return }

        if didCompleteInitialLoad {
            persist(items)
            return
        }

        switch ShelfPersistenceService.shared.load() {
        case .loaded(let loadedItems):
            items = loadedItems
            persistenceIssue = nil
            didCompleteInitialLoad = true
        case .failed(let issue):
            persistenceIssue = issue
        }
    }

    func revealPersistenceIssue() {
        guard let url = persistenceIssue?.backupURL ?? persistenceIssue?.sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    private func replaceItems(_ updatedItems: [ShelfItem]) -> Bool {
        guard didCompleteInitialLoad else { return false }
        guard persist(updatedItems) else { return false }
        items = updatedItems
        return true
    }

    @discardableResult
    private func persist(_ items: [ShelfItem]) -> Bool {
        switch ShelfPersistenceService.shared.save(items) {
        case .success:
            persistenceIssue = nil
            return true
        case .failure(let issue):
            persistenceIssue = issue
            return false
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
