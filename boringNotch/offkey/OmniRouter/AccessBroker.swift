import Foundation

final class RouterScope {
    let url: URL
    private let started: Bool

    init(bookmark: RouterBookmark) throws {
        var stale = false
        do {
            let options: URL.BookmarkResolutionOptions = bookmark.securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
            url = try URL(resolvingBookmarkData: bookmark.data, options: options,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw RouterFailure.access("书签无法解析，请重新选择：" + RouterFailure.message(for: error)) }
        guard !stale else { throw RouterFailure.access("目录或文件书签已失效，请重新选择。") }
        if let original = bookmark.location,
           url.resolvingSymlinksInPath().standardizedFileURL.pathComponents != original.standardizedFileURL.pathComponents {
            throw RouterFailure.access("授权目标路径已变化，请重新选择原目标。")
        }
        started = url.startAccessingSecurityScopedResource()
        // false can also mean that this process already has access; actual I/O decides.
    }

    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

enum RouterAccess {
    static let indexName = "万有引力｜万物总索引.md"
    static let support = URL.applicationSupportDirectory.appendingPathComponent("OmniRouter", isDirectory: true)

    // A suggested location for the system chooser, never an access grant.
    static var iCloudDrive: URL {
        let home = NSHomeDirectoryForUser(NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static func displayLocation(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if let index = parts.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + Array(parts.dropFirst(index + 1))).joined(separator: " → ")
        }
        if let index = parts.firstIndex(of: "iCloud~md~obsidian") {
            let names = parts.dropFirst(index + 1).filter { $0 != "Documents" }
            return (["iCloud Drive", "Obsidian"] + names).joined(separator: " → ")
        }
        if let index = parts.firstIndex(where: { $0.hasPrefix("GoogleDrive-") }) {
            let names = parts.dropFirst(index + 1).map { $0 == "My Drive" ? "我的云端硬盘" : $0 }
            return (["Google Drive"] + names).joined(separator: " → ")
        }
        return "本机文件夹：" + url.lastPathComponent
    }

    static func bookmark(_ url: URL, directory: Bool = false, owned: Bool = false) throws -> RouterBookmark {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        if directory {
            let values = try real.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw RouterFailure.invalid("请选择真实目录。") }
        } else {
            try RouterIO.regular(url)
        }
        let grantedURL = owned ? real : url
        return RouterBookmark(data: try grantedURL.bookmarkData(options: owned ? [] : [.withSecurityScope],
            includingResourceValuesForKeys: nil, relativeTo: nil), securityScoped: !owned, location: real)
    }

    static func inside(_ child: URL, _ parent: URL) -> Bool {
        let a = child.standardizedFileURL.pathComponents
        let b = parent.standardizedFileURL.pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }

    static func directory(_ url: URL) throws -> URL {
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        guard try real.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw RouterFailure.access("授权目录不可用，请重新选择。")
        }
        return real
    }

    static func archiveLocation(in granted: URL) -> URL {
        granted.lastPathComponent == "万物仓" ? granted : granted.appendingPathComponent("万物仓", isDirectory: true)
    }

    static func archiveDirectory(_ granted: URL, existingDestination: URL? = nil) throws -> URL {
        let parent = try directory(granted)
        let location = archiveLocation(in: parent)
        if let existingDestination {
            // Existing journals retain their authoritative destination, including older archives.
            let original = existingDestination.deletingLastPathComponent().deletingLastPathComponent()
            let path = original.standardizedFileURL.pathComponents
            guard path == parent.standardizedFileURL.pathComponents || path == location.standardizedFileURL.pathComponents else {
                throw RouterFailure.conflict("原归档落点不在授权目录内，请重新授权原目录。")
            }
            guard original.resolvingSymlinksInPath().standardizedFileURL == original.standardizedFileURL else {
                throw RouterFailure.conflict("归档目录变成符号链接，未写入。")
            }
            return try directory(original)
        }
        try RouterIO.coordinated(parent, writing: true) { _ in
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            guard location.resolvingSymlinksInPath().standardizedFileURL == location.standardizedFileURL else {
                throw RouterFailure.conflict("万物仓是符号链接，未写入。")
            }
        }
        return try directory(location)
    }
}

final class RouterJournal {
    let directory: URL
    init(directory: URL = RouterAccess.support) { self.directory = directory }

    func save(_ transaction: RouterTransaction) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(transaction)
        try RouterIO.durableData(data, to: recordURL(transaction.operationID))
    }

    func load(_ id: UUID) throws -> RouterTransaction? {
        let url = recordURL(id)
        do { return try JSONDecoder().decode(RouterTransaction.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func all() throws -> [RouterTransaction] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { try JSONDecoder().decode(RouterTransaction.self, from: Data(contentsOf: $0)) }
    }

    func saveSettings(_ settings: RouterSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RouterIO.durableData(JSONEncoder().encode(settings), to: directory.appendingPathComponent("settings.json"))
    }

    func loadSettings() throws -> RouterSettings? {
        let settings: RouterSettings
        do { settings = try JSONDecoder().decode(RouterSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json"))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        for bookmark in [settings.archive, settings.indexParent] {
            let scope = try RouterScope(bookmark: bookmark)
            try withExtendedLifetime(scope) { _ = try RouterAccess.directory(scope.url) }
        }
        _ = try all()
        return settings
    }

    private func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
