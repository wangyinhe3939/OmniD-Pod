import CryptoKit
import Darwin
import Foundation
import ImageIO

struct OffKeyFileInspection: Equatable {
    let url: URL
    let typeName: String
    let fileExtension: String
    let pixelWidth: Int?
    let pixelHeight: Int?
    let byteCount: UInt64
    let sha256: String
}

struct OffKeyNamingRule: Equatable {
    var prefix: String
    var digits: Int

    func validated() throws -> Self {
        guard digits == 2 || digits == 3 else {
            throw OffKeyNamingError.invalidDigits
        }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-"))
        guard prefix.count <= 24,
              prefix.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw OffKeyNamingError.invalidPrefix
        }
        return self
    }
}

struct OffKeyNamingScan {
    let usedNumbers: [Int]
    let gaps: [Int]
    let maximum: Int
    let next: Int
    let duplicateURLs: [URL]
    let filesByNumber: [Int: [URL]]
    let gapsTruncated: Bool
}

enum OffKeyNamingError: LocalizedError, Equatable {
    case missingLocation
    case notRegularFile
    case notRealDirectory
    case symbolicLinkInPath
    case unsupportedImageType
    case unknownExtensionlessType
    case invalidDigits
    case invalidPrefix
    case invalidShortName
    case filenameTooLong
    case numberAlreadyUsed
    case duplicateFound
    case sourceChanged
    case crossVolumeMove
    case destinationExists
    case renameFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingLocation:
            return "位置不存在或无法读取。"
        case .notRegularFile:
            return "请选择单个普通文件，不支持目录或符号链接。"
        case .notRealDirectory:
            return "请选择真实文件夹，不支持符号链接。"
        case .symbolicLinkInPath:
            return "路径经过符号链接，请选择真实位置。"
        case .unsupportedImageType:
            return "检测到图片格式，但尚不支持安全确定其扩展名。"
        case .unknownExtensionlessType:
            return "无法可靠识别此无扩展名文件的格式；文件未修改。"
        case .invalidDigits:
            return "编号位数请选择 2 或 3。"
        case .invalidPrefix:
            return "前缀仅支持字母、数字、下划线或短横线，也可以留空。"
        case .invalidShortName:
            return "请填写 1–80 字的短名称，不含斜线、冒号或换行。"
        case .filenameTooLong:
            return "文件名过长，请缩短名称。"
        case .numberAlreadyUsed:
            return "此编号已被使用，请重新扫描或选择其他编号。"
        case .duplicateFound:
            return "发现完全相同文件；请先定位已有文件，或明确选择仍然保留副本。"
        case .sourceChanged:
            return "原文件状态已改变，请重新选择。"
        case .crossVolumeMove:
            return "目标位于另一磁盘；安全移动仅支持同一磁盘，原文件未修改。"
        case .destinationExists:
            return "目标名称已存在，未覆盖任何文件。"
        case .renameFailed(let code):
            return "未能改名或移动：\(String(cString: strerror(code)))"
        }
    }
}

enum OffKeyNamingCore {
    static func inspectFile(at url: URL) throws -> OffKeyFileInspection {
        try validateRealLocation(url, expectsDirectory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let detected = try detectType(at: url)
        return OffKeyFileInspection(
            url: url,
            typeName: detected.name,
            fileExtension: detected.extension,
            pixelWidth: detected.width,
            pixelHeight: detected.height,
            byteCount: byteCount,
            sha256: try streamingSHA256(of: url)
        )
    }

    static func scanDirectory(
        _ directory: URL,
        rule: OffKeyNamingRule,
        sourceURL: URL?
    ) throws -> OffKeyNamingScan {
        let rule = try rule.validated()
        try validateRealLocation(directory, expectsDirectory: true)
        let sourceInspection = try sourceURL.map(inspectFile)
        let escapedPrefix = NSRegularExpression.escapedPattern(for: rule.prefix)
        let pattern = "^\(escapedPrefix)([0-9]{\(rule.digits),})(?=$|[｜| ._-])"
        let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )

        var numbers = Set<Int>()
        var duplicates: [URL] = []
        var filesByNumber: [Int: [URL]] = [:]

        for file in files {
            guard (try? validateRealLocation(file, expectsDirectory: false)) != nil else { continue }
            let filename = file.lastPathComponent
            let range = NSRange(filename.startIndex..., in: filename)
            if let match = expression.firstMatch(in: filename, range: range),
               let numberRange = Range(match.range(at: 1), in: filename),
               let number = Int(filename[numberRange]),
               number > 0 {
                numbers.insert(number)
                filesByNumber[number, default: []].append(file)
            }

            if let sourceInspection,
               file.standardizedFileURL != sourceURL?.standardizedFileURL,
               (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(sourceInspection.byteCount),
               try streamingSHA256(of: file) == sourceInspection.sha256 {
                duplicates.append(file)
            }
        }

        let used = numbers.sorted()
        let maximum = used.last ?? 0
        var gaps: [Int] = []
        var candidate = 1
        while candidate < maximum, gaps.count < 1_000 {
            if !numbers.contains(candidate) { gaps.append(candidate) }
            candidate += 1
        }

        return OffKeyNamingScan(
            usedNumbers: used,
            gaps: gaps,
            maximum: maximum,
            next: maximum + 1,
            duplicateURLs: duplicates.sorted { $0.path < $1.path },
            filesByNumber: filesByNumber,
            gapsTruncated: candidate < maximum
        )
    }

    static func filename(
        rule: OffKeyNamingRule,
        number: Int,
        shortName: String,
        fileExtension: String
    ) throws -> String {
        let rule = try rule.validated()
        let trimmed = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/:\n\r\0")
        guard number > 0,
              !trimmed.isEmpty,
              trimmed.count <= 80,
              trimmed.rangeOfCharacter(from: forbidden) == nil,
              fileExtension.rangeOfCharacter(from: forbidden) == nil
        else {
            throw OffKeyNamingError.invalidShortName
        }

        let padded = String(format: "%0*d", rule.digits, number)
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let result = "\(rule.prefix)\(padded)｜\(trimmed)\(suffix)"
        guard result.lengthOfBytes(using: .utf8) <= 255 else {
            throw OffKeyNamingError.filenameTooLong
        }
        return result
    }

    static func execute(
        source: URL,
        directory: URL,
        rule: OffKeyNamingRule,
        number: Int,
        shortName: String,
        allowDuplicate: Bool
    ) throws -> URL {
        let before = try identity(of: source, expectsDirectory: false)
        let targetDirectory = try identity(of: directory, expectsDirectory: true)
        guard before.device == targetDirectory.device else {
            throw OffKeyNamingError.crossVolumeMove
        }

        let inspection = try inspectFile(at: source)
        let scan = try scanDirectory(directory, rule: rule, sourceURL: source)
        let finalName = try filename(
            rule: rule,
            number: number,
            shortName: shortName,
            fileExtension: inspection.fileExtension
        )
        let destination = directory.appendingPathComponent(finalName)
        if destination.standardizedFileURL == source.standardizedFileURL { return source }

        if scan.filesByNumber[number, default: []].contains(where: {
            $0.standardizedFileURL != source.standardizedFileURL
        }) {
            throw OffKeyNamingError.numberAlreadyUsed
        }
        if !scan.duplicateURLs.isEmpty, !allowDuplicate {
            throw OffKeyNamingError.duplicateFound
        }

        guard try identity(of: source, expectsDirectory: false) == before else {
            throw OffKeyNamingError.sourceChanged
        }
        guard try identity(of: directory, expectsDirectory: true) == targetDirectory else {
            throw OffKeyNamingError.missingLocation
        }
        let renameResult = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard renameResult == 0 else {
            switch errno {
            case EXDEV: throw OffKeyNamingError.crossVolumeMove
            case EEXIST: throw OffKeyNamingError.destinationExists
            default: throw OffKeyNamingError.renameFailed(errno)
            }
        }
        return destination
    }

    static func streamingSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private static func identity(of url: URL, expectsDirectory: Bool) throws -> FileIdentity {
        try validateRealLocation(url, expectsDirectory: expectsDirectory)
        var value = stat()
        let status = url.path.withCString { lstat($0, &value) }
        guard status == 0 else {
            throw OffKeyNamingError.missingLocation
        }
        return FileIdentity(
            device: value.st_dev,
            inode: value.st_ino,
            size: value.st_size,
            modifiedSeconds: value.st_mtimespec.tv_sec,
            modifiedNanoseconds: value.st_mtimespec.tv_nsec
        )
    }

    private static func validateRealLocation(_ url: URL, expectsDirectory: Bool) throws {
        guard url.isFileURL else { throw OffKeyNamingError.missingLocation }
        var value = stat()
        let status = url.path.withCString { lstat($0, &value) }
        guard status == 0 else {
            throw OffKeyNamingError.missingLocation
        }
        guard (value.st_mode & S_IFMT) != S_IFLNK else {
            throw expectsDirectory ? OffKeyNamingError.notRealDirectory : OffKeyNamingError.notRegularFile
        }
        if expectsDirectory {
            guard (value.st_mode & S_IFMT) == S_IFDIR else { throw OffKeyNamingError.notRealDirectory }
        } else {
            guard (value.st_mode & S_IFMT) == S_IFREG else { throw OffKeyNamingError.notRegularFile }
        }

        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            let parentStatus = parent.path.withCString { lstat($0, &value) }
            guard parentStatus == 0 else {
                throw OffKeyNamingError.missingLocation
            }
            guard (value.st_mode & S_IFMT) != S_IFLNK else {
                throw OffKeyNamingError.symbolicLinkInPath
            }
            let next = parent.deletingLastPathComponent()
            guard next != parent else { break }
            parent = next
        }
    }

    private static func detectType(at url: URL) throws -> (
        name: String,
        extension: String,
        width: Int?,
        height: Int?
    ) {
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(imageSource) as String? {
            let mappings: [String: (String, String)] = [
                "public.png": ("PNG", "png"),
                "public.jpeg": ("JPEG", "jpg"),
                "com.compuserve.gif": ("GIF", "gif"),
                "public.tiff": ("TIFF", "tiff"),
                "com.microsoft.bmp": ("BMP", "bmp"),
                "public.heic": ("HEIC", "heic"),
                "public.heif": ("HEIF", "heif"),
                "org.webmproject.webp": ("WebP", "webp")
            ]
            guard let mapping = mappings[type] else {
                throw OffKeyNamingError.unsupportedImageType
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any]
            return (
                mapping.0,
                mapping.1,
                (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 4_096) ?? Data()
        try? handle.close()
        if header.starts(with: Data("%PDF-".utf8)) {
            return ("PDF", "pdf", nil, nil)
        }
        if let text = String(data: header, encoding: .utf8),
           text.range(of: "<svg", options: .caseInsensitive) != nil {
            return ("SVG", "svg", nil, nil)
        }
        if header.count >= 12,
           header.subdata(in: 4..<8) == Data("ftyp".utf8),
           header.subdata(in: 8..<12) == Data("qt  ".utf8) {
            return ("QuickTime", "mov", nil, nil)
        }

        let existingExtension = url.pathExtension.lowercased()
        guard !existingExtension.isEmpty else {
            throw OffKeyNamingError.unknownExtensionlessType
        }
        return ("未识别格式（保留原扩展名）", existingExtension, nil, nil)
    }
}

struct OffKeyNamingLocation: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    var bookmarkData: Data
    var prefix: String
    var digitCount: Int
    var isPinned: Bool
    var lastUsedDate: Date
}

struct OffKeyNamingLocationStore {
    private let defaults: UserDefaults
    private let key = "DDOffKey.NamingLocations.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func locations() -> [OffKeyNamingLocation] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([OffKeyNamingLocation].self, from: data)
        else { return [] }
        return values.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastUsedDate > $1.lastUsedDate
        }
    }

    func remember(
        url: URL,
        rule: OffKeyNamingRule,
        pinned: Bool
    ) throws {
        _ = try rule.validated()
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let identifier = url.standardizedFileURL.path
        var values = locations().filter { $0.id != identifier }
        values.insert(
            OffKeyNamingLocation(
                id: identifier,
                displayName: url.lastPathComponent,
                bookmarkData: bookmark,
                prefix: rule.prefix,
                digitCount: rule.digits,
                isPinned: pinned,
                lastUsedDate: Date()
            ),
            at: 0
        )
        var unpinned = 0
        values = values.filter { location in
            if location.isPinned { return true }
            defer { unpinned += 1 }
            return unpinned < 12
        }
        defaults.set(try JSONEncoder().encode(values), forKey: key)
    }

    func remove(id: String) throws {
        let values = locations().filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(values), forKey: key)
    }

    func resolve(_ location: OffKeyNamingLocation) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: location.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }
}
