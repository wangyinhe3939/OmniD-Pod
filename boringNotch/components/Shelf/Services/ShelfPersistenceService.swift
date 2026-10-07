//
//  ShelfPersistenceService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation

// Access model types
@_exported import struct Foundation.URL

enum ShelfPersistenceIssueKind: Equatable {
    case storageUnavailable
    case corruptedData
    case saveFailed
}

struct ShelfPersistenceIssue: Error, Equatable {
    let kind: ShelfPersistenceIssueKind
    let title: String
    let message: String
    let sourceURL: URL?
    let backupURL: URL?
}

enum ShelfPersistenceLoadResult {
    case loaded([ShelfItem])
    case failed(ShelfPersistenceIssue)
}

final class ShelfPersistenceService {
    static let shared = ShelfPersistenceService()

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func load() -> ShelfPersistenceLoadResult {
        let fileURL: URL
        do {
            fileURL = try persistenceFileURL()
        } catch {
            return .failed(storageUnavailableIssue(error: error))
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .loaded([])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .failed(
                ShelfPersistenceIssue(
                    kind: .storageUnavailable,
                    title: "文件暂存数据不可用",
                    message: "现有 items.json 无法读取，原文件没有改动，自动保存已暂停。\(error.localizedDescription)",
                    sourceURL: fileURL,
                    backupURL: nil
                )
            )
        }

        do {
            return .loaded(try decoder.decode([ShelfItem].self, from: data))
        } catch {
            return .failed(corruptedDataIssue(for: fileURL, decodingError: error))
        }
    }

    func save(_ items: [ShelfItem]) -> Result<Void, ShelfPersistenceIssue> {
        do {
            let fileURL = try persistenceFileURL()
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
            return .success(())
        } catch {
            return .failure(
                ShelfPersistenceIssue(
                    kind: .saveFailed,
                    title: "文件暂存改动尚未保存",
                    message: "当前内容仍保留在窗口中，但最新改动无法写入；旧 items.json 没有被替换。\(error.localizedDescription)",
                    sourceURL: try? existingPersistenceFileURL(),
                    backupURL: nil
                )
            )
        }
    }

    private func persistenceFileURL() throws -> URL {
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = supportURL
            .appendingPathComponent("DDNotch", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("items.json", isDirectory: false)
    }

    private func existingPersistenceFileURL() throws -> URL {
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return supportURL
            .appendingPathComponent("DDNotch", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent("items.json", isDirectory: false)
    }

    private func storageUnavailableIssue(error: Error) -> ShelfPersistenceIssue {
        ShelfPersistenceIssue(
            kind: .storageUnavailable,
            title: "文件暂存数据不可用",
            message: "无法准备 Application Support 目录；没有冒充使用临时存储，自动保存已暂停。\(error.localizedDescription)",
            sourceURL: nil,
            backupURL: nil
        )
    }

    private func corruptedDataIssue(for fileURL: URL, decodingError: Error) -> ShelfPersistenceIssue {
        let backupURL = Self.corruptionBackupURL(
            for: fileURL,
            date: Date(),
            token: String(UUID().uuidString.prefix(8))
        )

        do {
            try fileManager.copyItem(at: fileURL, to: backupURL)
            return ShelfPersistenceIssue(
                kind: .corruptedData,
                title: "文件暂存数据需要恢复",
                message: "原 items.json 没有改动，已建立恢复副本 \(backupURL.lastPathComponent)，自动保存已暂停。\(decodingError.localizedDescription)",
                sourceURL: fileURL,
                backupURL: backupURL
            )
        } catch {
            return ShelfPersistenceIssue(
                kind: .corruptedData,
                title: "文件暂存数据需要恢复",
                message: "原 items.json 没有改动，但恢复副本建立失败，自动保存已暂停。读取错误：\(decodingError.localizedDescription)；备份错误：\(error.localizedDescription)",
                sourceURL: fileURL,
                backupURL: nil
            )
        }
    }

    static func corruptionBackupURL(for sourceURL: URL, date: Date, token: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let timestamp = formatter.string(from: date)
        let filename = "items.corrupt-\(timestamp)-\(token).json"
        return sourceURL.deletingLastPathComponent().appendingPathComponent(filename, isDirectory: false)
    }
}
