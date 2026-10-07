import CryptoKit
import Darwin
import Foundation

enum RouterIO {
    static func coordinated<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        guard !Thread.isMainThread else { throw RouterFailure.io("文件协调必须在后台执行。") }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { location in
            result = Result { try body(location) }
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing { coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor) }
        if let error = coordinationError { throw error }
        guard let result = result else { throw RouterFailure.io("文件协调没有返回结果。") }
        return try result.get()
    }

    static func handle<T>(_ handle: FileHandle, _ body: (FileHandle) throws -> T) throws -> T {
        let value: T
        do { value = try body(handle) }
        catch {
            let original = error
            do { try handle.close() }
            catch { throw RouterFailure.io("\(RouterFailure.message(for: original))；关闭文件也失败：\(RouterFailure.message(for: error))") }
            throw original
        }
        try handle.close()
        return value
    }

    static func open(_ url: URL, flags: Int32, mode: mode_t = 0o600) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func regular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isAliasFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.isPackage != true, values.isAliasFile != true else {
            throw RouterFailure.invalid("只接收普通文件；目录、包、别名及符号链接保留原样。")
        }
    }

    static func fingerprint(_ url: URL) throws -> RouterFingerprint {
        try regular(url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        var hash = SHA256()
        var count: UInt64 = 0
        try handle(open(url, flags: O_RDONLY)) { reader in
            while let bytes = try reader.read(upToCount: 1_048_576), !bytes.isEmpty {
                hash.update(data: bytes)
                count += UInt64(bytes.count)
            }
        }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        for key: FileAttributeKey in [.systemNumber, .systemFileNumber, .size, .modificationDate, .posixPermissions] {
            guard (before[key] as? NSObject) == (after[key] as? NSObject) else { throw RouterFailure.changed }
        }
        guard let size = before[.size] as? NSNumber, UInt64(truncating: size) == count,
              let device = before[.systemNumber] as? NSNumber,
              let inode = before[.systemFileNumber] as? NSNumber,
              let modified = before[.modificationDate] as? Date,
              let mode = before[.posixPermissions] as? NSNumber else { throw RouterFailure.changed }
        return RouterFingerprint(device: device.uint64Value, inode: inode.uint64Value,
            size: count, modified: modified.timeIntervalSince1970, permissions: mode.uint16Value,
            digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func writeExclusive(_ data: Data, to url: URL) throws {
        try handle(open(url, flags: O_WRONLY | O_CREAT | O_EXCL)) { writer in
            try writer.write(contentsOf: data)
            try writer.synchronize()
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func durableData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try handle(open(url, flags: O_RDWR)) { try $0.synchronize() }
        try handle(open(url.deletingLastPathComponent(), flags: O_RDONLY)) { try $0.synchronize() }
    }

    static func commit(stage: URL, destination: URL, expected: RouterFingerprint? = nil, allowedRoot: URL? = nil) throws {
        guard !Thread.isMainThread else { throw RouterFailure.io("文件提交必须在后台执行。") }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        let parent = destination.deletingLastPathComponent().standardizedFileURL.pathComponents
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: stage, options: .forMoving,
            writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            result = Result {
                let pathsValid: Bool
                if let root = allowedRoot {
                    pathsValid = RouterAccess.inside(from, root) && RouterAccess.inside(to, root)
                        && from.resolvingSymlinksInPath().standardizedFileURL == from.standardizedFileURL
                        && to.resolvingSymlinksInPath().standardizedFileURL == to.standardizedFileURL
                } else {
                    pathsValid = from.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.pathComponents == parent
                        && to.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.pathComponents == parent
                }
                guard pathsValid else {
                    throw RouterFailure.conflict("暂存或目标目录路径已变化，原文件保留。")
                }
                if let expected = expected {
                    let actual = try fingerprint(from)
                    guard actual.hasSameContent(as: expected), actual.permissions & 0o111 == expected.permissions & 0o111 else {
                        throw RouterFailure.conflict("暂存校验后内容或执行属性改变，原文件保留。")
                    }
                }
                // The native exclusive rename refuses case-insensitive and Unicode collisions.
                guard renameatx_np(AT_FDCWD, from.path, AT_FDCWD, to.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                try handle(open(to, flags: O_RDONLY)) { try $0.synchronize() }
                try handle(open(to.deletingLastPathComponent(), flags: O_RDONLY)) { try $0.synchronize() }
                if from.deletingLastPathComponent() != to.deletingLastPathComponent() {
                    try handle(open(from.deletingLastPathComponent(), flags: O_RDONLY)) { try $0.synchronize() }
                }
            }
        }
        if let error = coordinationError { throw error }
        guard let result = result else { throw RouterFailure.io("提交协调没有返回结果。") }
        try result.get()
    }

    static func fingerprintIfPresent(_ url: URL) throws -> RouterFingerprint? {
        do { return try coordinated(url, writing: false, fingerprint) }
        catch let error as NSError where
            (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return nil }
    }

    @discardableResult static func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}
