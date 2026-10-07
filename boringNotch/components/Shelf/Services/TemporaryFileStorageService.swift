//
//  TemporaryFileStorageService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum TempFileType {
    case data(Data, suggestedName: String?)
    case text(String)
    case url(URL)
}

class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()
    
    // MARK: - Public Interface
    
    /// Creates a temporary file and tracks it for manual cleanup
    func createTempFile(for type: TempFileType) async -> URL? {
        return await withCheckedContinuation { continuation in
            let result = createTempFile(for: type)
            continuation.resume(returning: result)
        }
    }
    
    func removeTemporaryFileIfNeeded(at url: URL) {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())

        guard url.path.hasPrefix(tempDirectory.path) else {
            print("Attempted to remove temporary file outside temp directory: \(url.path)")
            return
        }

        let folderURL = url.deletingLastPathComponent()

        do {
            try FileManager.default.removeItem(at: url)
            print("Deleted file: \(url.path)")

            let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
            if contents.isEmpty {
                try FileManager.default.removeItem(at: folderURL)
                print("Folder was empty, deleted folder: \(folderURL.path)")
            } else {
                print("Folder not deleted — it still contains \(contents.count) item(s).")
            }

        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Implementation
    
    private func createTempFile(for type: TempFileType) -> URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let uuid = UUID().uuidString
        
        switch type {
        case .data(let data, let suggestedName):
            let filename = safeFilename(suggestedName, fallback: "Untitled.dat")
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            guard let fileURL = containedFileURL(in: dirURL, filename: filename) else {
                print("❌ Refusing unsafe temporary filename: \(suggestedName ?? "<nil>")")
                return nil
            }
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                return fileURL
            } catch {
                print("Error: \(error)")
                return nil
            }
            
        case .text(let string):
            let filename = "\(uuid).txt"
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)
            
            guard let data = string.data(using: .utf8) else {
                print("❌ Failed to convert text to data")
                return nil
            }
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                print("Error: \(error)")
                return nil
            }
            
        case .url(let url):
            let filename = "\(url.host ?? uuid).webloc"
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)
            
            let weblocContent = createWeblocContent(for: url)
            guard let data = weblocContent.data(using: String.Encoding.utf8) else {
                print("❌ Failed to create webloc data")
                return nil
            }
            
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                print("Error: \(error)")
                return nil
            }
        }
    }
    
    private func createFile(at url: URL, data: Data) -> URL? {
        do {
            try data.write(to: url)
            return url
        } catch {
            print("❌ Failed to create temp file at \(url.path): \(error)")
            return nil
        }
    }
    func createZip(from urls: [URL], suggestedName: String? = nil) async -> URL? {
        guard !urls.isEmpty else {
            print("❌ Cannot create zip: no input items were provided")
            return nil
        }

        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let uuid = UUID().uuidString
        let workingDir = tempDir.appendingPathComponent("zip_\(uuid)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: workingDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create zip working directory: \(error)")
            return nil
        }

        var shouldRemoveWorkingDirectory = true
        defer {
            if shouldRemoveWorkingDirectory,
               fileManager.fileExists(atPath: workingDir.path) {
                do {
                    try fileManager.removeItem(at: workingDir)
                } catch {
                    print("❌ Failed to cleanup zip working directory \(workingDir.path): \(error)")
                }
            }
        }

        // Helper to run zip process
        func runZip(arguments: [String], currentDirectory: URL) -> Bool {
            let proc = Process()
            let diagnostics = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.arguments = arguments
            proc.currentDirectoryURL = currentDirectory
            proc.standardOutput = diagnostics
            proc.standardError = diagnostics

            do {
                try proc.run()
                let diagnosticData = diagnostics.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()

                guard proc.terminationStatus == 0 else {
                    let errorMessage = String(data: diagnosticData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let details: String
                    if let errorMessage, !errorMessage.isEmpty {
                        details = errorMessage
                    } else {
                        details = "no diagnostic output"
                    }
                    print("❌ zip exited with status \(proc.terminationStatus): \(details)")
                    return false
                }

                return true
            } catch {
                print("❌ Failed to run zip: \(error)")
                return false
            }
        }

        func isUsableArchive(_ archiveURL: URL) -> Bool {
            guard fileManager.fileExists(atPath: archiveURL.path) else {
                print("❌ zip reported success but produced no archive at \(archiveURL.path)")
                return false
            }

            let fileSize = try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let fileSize, fileSize > 0 else {
                print("❌ zip produced an empty or unreadable archive at \(archiveURL.path)")
                return false
            }

            return true
        }

        // Single-item optimization: do not copy contents into the working dir.
        if urls.count == 1, let src = urls.first {
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let baseName = src.lastPathComponent
            let archiveName: String
            if isDir {
                // Folder: name as FolderName.zip and include the folder itself in the archive
                archiveName = "\(baseName).zip"
                let archiveURL = workingDir.appendingPathComponent(archiveName)
                // Run zip from the parent directory so the folder is stored as top-level entry
                let parent = src.deletingLastPathComponent()
                let args = ["-r", "-q", archiveURL.path, "./\(baseName)"]
                let ok = runZip(arguments: args, currentDirectory: parent)
                if ok, isUsableArchive(archiveURL) {
                    shouldRemoveWorkingDirectory = false
                    return archiveURL
                } else {
                    return nil
                }
            } else {
                // File: include the file only (no parent folders). Name should include original extension.
                archiveName = "\(baseName).zip"
                let archiveURL = workingDir.appendingPathComponent(archiveName)
                let parent = src.deletingLastPathComponent()
                // -j to junk paths and store only the file
                let args = ["-j", "-q", archiveURL.path, "./\(baseName)"]
                let ok = runZip(arguments: args, currentDirectory: parent)
                if ok, isUsableArchive(archiveURL) {
                    shouldRemoveWorkingDirectory = false
                    return archiveURL
                } else {
                    return nil
                }
            }
        }

        let archiveName = safeFilename(suggestedName, fallback: "Archive.zip")
        guard let archiveURL = containedFileURL(in: workingDir, filename: archiveName) else {
            print("❌ Refusing unsafe archive filename: \(suggestedName ?? "<nil>")")
            return nil
        }
        let contentDir = workingDir.appendingPathComponent("contents", isDirectory: true)

        do {
            try fileManager.createDirectory(at: contentDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create zip content directory: \(error)")
            return nil
        }

        // Multi-item: keep staged inputs in a child directory and write the archive
        // alongside it. Writing the archive into the directory being zipped would
        // make `zip` recursively include its own growing output.
        for src in urls {
            let dest = contentDir.appendingPathComponent(src.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: dest.path) {
                    // Avoid collision by appending a suffix
                    let unique = "\(UUID().uuidString)_\(src.lastPathComponent)"
                    try fileManager.copyItem(at: src, to: contentDir.appendingPathComponent(unique))
                } else {
                    try fileManager.copyItem(at: src, to: dest)
                }
            } catch {
                print("❌ Failed to copy \(src.path) to zip working directory; archive aborted: \(error)")
                return nil
            }
        }

        let args = ["-r", "-q", archiveURL.path, "."]
        let ok = runZip(arguments: args, currentDirectory: contentDir)
        if ok, isUsableArchive(archiveURL) {
            do {
                try fileManager.removeItem(at: contentDir)
            } catch {
                print("❌ Failed to cleanup copied items after zip; archive discarded: \(error)")
                return nil
            }
            shouldRemoveWorkingDirectory = false
            return archiveURL
        } else {
            return nil
        }
    }

    private func safeFilename(_ suggestedName: String?, fallback: String) -> String {
        guard let suggestedName else { return fallback }

        let normalizedSeparators = suggestedName.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = normalizedSeparators
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let withoutControlCharacters = String(lastComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })

        guard !withoutControlCharacters.isEmpty,
              withoutControlCharacters != ".",
              withoutControlCharacters != ".." else {
            return fallback
        }
        return withoutControlCharacters
    }

    private func containedFileURL(in directory: URL, filename: String) -> URL? {
        let standardizedDirectory = directory.standardizedFileURL
        let candidate = standardizedDirectory.appendingPathComponent(filename).standardizedFileURL
        guard candidate.deletingLastPathComponent() == standardizedDirectory else { return nil }
        return candidate
    }
    
    // MARK: - Content Creation Helpers
    
    
    private func createWeblocContent(for url: URL) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>URL</key>
            <string>\(url.absoluteString)</string>
        </dict>
        </plist>
        """
    }
}
