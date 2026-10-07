import CryptoKit
import ImageIO
import XCTest
@testable import DDOffKeyCore

final class OffKeyNotesCoreTests: XCTestCase {
    func testWorkspaceRoundTripLegacyAndCarryForward() throws {
        let legacy = Data(#"{"format":"double-meaning-notes","version":1,"entries":[{"id":"old","title":"原记录","notes":"保留正文"}],"trash":[]}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try withTemporaryDirectory { directory in
            let repository = OffKeyNotesRepository(storeURL: directory.appendingPathComponent("Notes.json"))
            try legacy.write(to: repository.storeURL)
            var document = try repository.load()
            XCTAssertNil(document.entries[0].workspace)
            XCTAssertEqual(document.workspaceRecords(isTask: false, showCompleted: false).count, 1)
            document.workspaceDraft = OffKeyWorkspaceDraft(text: "草稿\n第二行", project: "我的项目")
            document.entries += [
                OffKeyNoteRecord(id: "past", title: "未完成", workspace: .init(isTask: true,
                    scheduledDate: now.addingTimeInterval(-86_400), project: "我的项目")),
                OffKeyNoteRecord(id: "future", title: "明天", workspace: .init(isTask: true,
                    scheduledDate: now.addingTimeInterval(172_800))),
                OffKeyNoteRecord(id: "undated", title: "未安排", workspace: .init(isTask: true)),
                OffKeyNoteRecord(id: "completed", title: "完成", workspace: .init(isTask: true, completed: true))
            ]
            try repository.save(document)
            XCTAssertEqual(try repository.load(), document)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Notes-before-workspace.json")), legacy)
            XCTAssertEqual(document.workspaceRecords(isTask: true, showCompleted: false, now: now).map(\.id), ["past", "undated"])
            XCTAssertEqual(document.workspaceRecords(isTask: true, showCompleted: true, project: "我的项目", now: now).map(\.id), ["past"])
            try repository.save(document)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Notes-before-workspace.json")), legacy)
            var invalid = document
            invalid.workspaceDraft?.text = String(repeating: "字", count: OffKeyNotesDocument.maxNotesCount + 1)
            XCTAssertThrowsError(try repository.save(invalid))
            invalid = document
            invalid.entries[1].workspace?.createdAt = Date(timeIntervalSince1970: .infinity)
            XCTAssertThrowsError(try repository.save(invalid))
            invalid = document
            invalid.workspaceDraft?.reminderDate = Date(timeIntervalSince1970: .infinity)
            XCTAssertThrowsError(try repository.save(invalid))
            invalid = document
            invalid.entries[1].workspace?.reminderIdentifier = "duplicate"
            invalid.entries[2].workspace?.reminderIdentifier = "duplicate"
            XCTAssertThrowsError(try repository.save(invalid))
            XCTAssertEqual(try repository.load(), document, "失败不能覆盖已保存内容")
        }
    }

    func testPermanentTrashDeletionAndEmptyTrashDoNotTouchActiveNotes() {
        let active = OffKeyNoteRecord(id: "active", title: "保留", notes: "正文")
        var document = OffKeyNotesDocument(
            entries: [active],
            trash: [
                OffKeyNoteRecord(id: "trash-one", title: "删除一", notes: ""),
                OffKeyNoteRecord(id: "trash-two", title: "删除二", notes: "")
            ]
        )

        XCTAssertTrue(document.permanentlyDeleteTrashRecord(id: "trash-one"))
        XCTAssertFalse(document.permanentlyDeleteTrashRecord(id: "missing"))
        XCTAssertEqual(document.entries, [active])
        XCTAssertEqual(document.trash.map(\.id), ["trash-two"])

        XCTAssertEqual(document.emptyTrash(), 1)
        XCTAssertEqual(document.emptyTrash(), 0)
        XCTAssertEqual(document.entries, [active])
        XCTAssertTrue(document.trash.isEmpty)
    }

    func testSaveReloadSearchAndStrictValidation() throws {
        try withTemporaryDirectory { directory in
            let repository = OffKeyNotesRepository(
                storeURL: directory.appendingPathComponent("Notes.json")
            )
            let document = OffKeyNotesDocument(
                entries: [OffKeyNoteRecord(id: "one", title: "一条记录", notes: "正文 内容")],
                trash: [OffKeyNoteRecord(id: "two", title: "旧记录", notes: "旧内容")]
            )

            try repository.save(document)
            XCTAssertEqual(try repository.load(), document)
            XCTAssertEqual(document.matching("一条 内容", inTrash: false).map(\.id), ["one"])
            XCTAssertTrue(document.matching("不存在", inTrash: false).isEmpty)

            let invalid = OffKeyNotesDocument(
                entries: [OffKeyNoteRecord(id: "same", title: "A", notes: "")],
                trash: [OffKeyNoteRecord(id: "same", title: "B", notes: "")]
            )
            XCTAssertThrowsError(try repository.save(invalid))
            XCTAssertEqual(try repository.load(), document)

            let oversizedTitle = OffKeyNotesDocument(
                entries: [
                    OffKeyNoteRecord(
                        id: "large-title",
                        title: String(repeating: "字", count: OffKeyNotesDocument.maxTitleCount + 1),
                        notes: ""
                    )
                ]
            )
            XCTAssertThrowsError(try repository.save(oversizedTitle)) { error in
                guard let notesError = error as? OffKeyNotesError,
                      case .titleTooLong = notesError
                else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

            let oversizedNotes = OffKeyNotesDocument(
                entries: [
                    OffKeyNoteRecord(
                        id: "large-notes",
                        title: "",
                        notes: String(repeating: "字", count: OffKeyNotesDocument.maxNotesCount + 1)
                    )
                ]
            )
            XCTAssertThrowsError(try repository.save(oversizedNotes)) { error in
                guard let notesError = error as? OffKeyNotesError,
                      case .notesTooLong = notesError
                else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
            XCTAssertEqual(try repository.load(), document)
        }
    }

    func testImportBackupRestoreAndBadImportPreservesCurrentFile() throws {
        try withTemporaryDirectory { directory in
            let repository = OffKeyNotesRepository(
                storeURL: directory.appendingPathComponent("Notes.json")
            )
            let before = OffKeyNotesDocument(
                entries: [OffKeyNoteRecord(id: "one", title: "导入前", notes: "保留")],
                trash: [OffKeyNoteRecord(id: "old", title: "旧", notes: "回收站")]
            )
            let incoming = OffKeyNotesDocument(
                entries: [OffKeyNoteRecord(id: "new", title: "导入后", notes: "新内容")],
                trash: []
            )
            try repository.save(before)

            let replaced = try repository.importDocument(incoming, into: before, mode: .replace)
            XCTAssertEqual(replaced.document, incoming)
            XCTAssertEqual(try repository.load(), incoming)
            XCTAssertEqual(
                try repository.decodeDocument(from: Data(contentsOf: repository.importBackupURL)),
                before
            )
            XCTAssertEqual(try repository.restoreImportBackup(), before)
            XCTAssertEqual(try repository.load(), before)
            XCTAssertEqual(
                try repository.decodeDocument(from: Data(contentsOf: repository.restoreRollbackURL)),
                incoming
            )

            let bad = OffKeyNotesDocument(
                entries: [OffKeyNoteRecord(id: "duplicate", title: "A", notes: "")],
                trash: [OffKeyNoteRecord(id: "duplicate", title: "B", notes: "")]
            )
            XCTAssertThrowsError(try repository.importDocument(bad, into: before, mode: .replace))
            XCTAssertEqual(try repository.load(), before)
        }
    }

    func testMergePreservesTrashAndReissuesConflictingID() throws {
        try withTemporaryDirectory { directory in
            let repository = OffKeyNotesRepository(
                storeURL: directory.appendingPathComponent("Notes.json")
            )
            let current = OffKeyNotesDocument(
                entries: [OffKeyNoteRecord(id: "same", title: "当前", notes: "A")],
                trash: [OffKeyNoteRecord(id: "trash-current", title: "旧记录", notes: "B")]
            )
            let incoming = OffKeyNotesDocument(
                entries: [OffKeyNoteRecord(id: "same", title: "不同版本", notes: "C")],
                trash: [OffKeyNoteRecord(id: "trash-new", title: "导入回收站", notes: "D")]
            )

            let merged = try repository.importDocument(incoming, into: current, mode: .merge)
            XCTAssertEqual(merged.addedCount, 2)
            XCTAssertEqual(merged.document.entries.count, 2)
            XCTAssertEqual(merged.document.trash.count, 2, "导入的回收站记录不能复活到 entries")
            XCTAssertTrue(merged.document.trash.contains { $0.id == "trash-new" })
            XCTAssertNotEqual(merged.document.entries.last?.id, "same")

            let identical = OffKeyNotesDocument(
                entries: [OffKeyNoteRecord(id: "same", title: "当前", notes: "A")],
                trash: []
            )
            let unchanged = try repository.importDocument(
                identical,
                into: merged.document,
                mode: .merge
            )
            XCTAssertEqual(unchanged.addedCount, 0)
            XCTAssertEqual(unchanged.document, merged.document)
        }
    }
}

final class OffKeyNamingCoreTests: XCTestCase {
    func testDetectsActualImageTypeAndStreamsSHA256() throws {
        try withTemporaryDirectory { directory in
            let disguisedJPEG = directory.appendingPathComponent("wrong.jpg")
            try writeOnePixelPNG(to: disguisedJPEG)

            let inspection = try OffKeyNamingCore.inspectFile(at: disguisedJPEG)
            XCTAssertEqual(inspection.typeName, "PNG")
            XCTAssertEqual(inspection.fileExtension, "png")
            XCTAssertEqual(inspection.pixelWidth, 1)
            XCTAssertEqual(inspection.pixelHeight, 1)

            let expected = SHA256.hash(data: try Data(contentsOf: disguisedJPEG))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(inspection.sha256, expected)
        }
    }

    func testScanFindsNumbersGapsAndSameHash() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source.bin")
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("same".utf8).write(to: source)
            try Data("one".utf8).write(to: destination.appendingPathComponent("G01｜一.txt"))
            try Data("three".utf8).write(to: destination.appendingPathComponent("G03｜三.txt"))
            try Data("same".utf8).write(to: destination.appendingPathComponent("副本.bin"))

            let scan = try OffKeyNamingCore.scanDirectory(
                destination,
                rule: OffKeyNamingRule(prefix: "G", digits: 2),
                sourceURL: source
            )
            XCTAssertEqual(scan.usedNumbers, [1, 3])
            XCTAssertEqual(scan.gaps, [2])
            XCTAssertEqual(scan.next, 4)
            XCTAssertEqual(scan.duplicateURLs.map(\.lastPathComponent), ["副本.bin"])
        }
    }

    func testAtomicNoOverwriteAndSameVolumeMove() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source.txt")
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("source".utf8).write(to: source)
            let existing = destination.appendingPathComponent("G01｜已有.txt")
            try Data("do-not-overwrite".utf8).write(to: existing)

            XCTAssertThrowsError(try OffKeyNamingCore.execute(
                source: source,
                directory: destination,
                rule: OffKeyNamingRule(prefix: "G", digits: 2),
                number: 1,
                shortName: "新的",
                allowDuplicate: true
            ))
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "do-not-overwrite")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

            let result = try OffKeyNamingCore.execute(
                source: source,
                directory: destination,
                rule: OffKeyNamingRule(prefix: "G", digits: 2),
                number: 2,
                shortName: "新的",
                allowDuplicate: true
            )
            XCTAssertEqual(result.lastPathComponent, "G02｜新的.txt")
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "source")
        }
    }

    func testRejectsSymbolicLink() throws {
        try withTemporaryDirectory { directory in
            let real = directory.appendingPathComponent("real.txt")
            let link = directory.appendingPathComponent("link.txt")
            try Data("value".utf8).write(to: real)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            XCTAssertThrowsError(try OffKeyNamingCore.inspectFile(at: link)) { error in
                XCTAssertEqual(error as? OffKeyNamingError, .notRegularFile)
            }
        }
    }
}

final class OffKeyLifecycleTests: XCTestCase {
    func testPermissionRoutingOpensMissingPermissionInOrder() {
        XCTAssertEqual(
            OffKeyPermissionKind.firstMissing(
                accessibilityGranted: false,
                inputMonitoringGranted: false
            ),
            .accessibility
        )
        XCTAssertEqual(
            OffKeyPermissionKind.firstMissing(
                accessibilityGranted: true,
                inputMonitoringGranted: false
            ),
            .inputMonitoring
        )
        XCTAssertNil(
            OffKeyPermissionKind.firstMissing(
                accessibilityGranted: true,
                inputMonitoringGranted: true
            )
        )
    }

    func testPermissionRoutesUseSpecificPrivacyPanes() {
        XCTAssertEqual(
            OffKeyPermissionKind.accessibility.systemSettingsURLs.map(\.absoluteString),
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            ]
        )
        XCTAssertEqual(
            OffKeyPermissionKind.inputMonitoring.systemSettingsURLs.map(\.absoluteString),
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
            ]
        )
    }

    func testCleaningRestoresSingleMediaTapMode() {
        var lifecycle = OffKeyTapLifecycle()
        lifecycle.setMediaRequested(true)
        XCTAssertEqual(lifecycle.mode, .mediaKeys)
        lifecycle.beginCleaning()
        XCTAssertEqual(lifecycle.mode, .keyboardCleaning)
        lifecycle.finishCleaning()
        XCTAssertEqual(lifecycle.mode, .mediaKeys)
    }

    func testDisablingMediaDuringCleaningRestoresIdle() {
        var lifecycle = OffKeyTapLifecycle()
        lifecycle.setMediaRequested(true)
        lifecycle.beginCleaning()
        lifecycle.setMediaRequested(false)
        XCTAssertEqual(lifecycle.mode, .keyboardCleaning)
        lifecycle.finishCleaning()
        XCTAssertEqual(lifecycle.mode, .idle)
    }

    func testCleaningBlocksKeyboardButPassesPointerAndAuxMouse() {
        XCTAssertTrue(OffKeyCleaningEventPolicy.shouldSuppress(.keyDown))
        XCTAssertTrue(OffKeyCleaningEventPolicy.shouldSuppress(.keyUp))
        XCTAssertTrue(OffKeyCleaningEventPolicy.shouldSuppress(.flagsChanged))
        XCTAssertTrue(OffKeyCleaningEventPolicy.shouldSuppress(.systemDefined(subtype: 8)))
        XCTAssertFalse(OffKeyCleaningEventPolicy.shouldSuppress(.systemDefined(subtype: 7)))
        XCTAssertFalse(OffKeyCleaningEventPolicy.shouldSuppress(.pointer))
    }

    func testLatestScanRequestWins() {
        var gate = OffKeyScanRequestGate()
        let first = gate.request()
        XCTAssertEqual(first, 1)
        XCTAssertNil(gate.request())
        XCTAssertNil(gate.request())
        XCTAssertEqual(gate.latestGeneration, 3)
        XCTAssertEqual(gate.finish(1), 3)
        XCTAssertEqual(gate.runningGeneration, 3)
        XCTAssertNil(gate.finish(3))
        XCTAssertNil(gate.runningGeneration)
    }

    func testCleaningDeadlineUsesWallClockInsteadOfTimerTicks() {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = OffKeyCleaningDeadline(duration: 15, now: start)
        XCTAssertEqual(deadline.remainingSeconds(at: start), 15)
        XCTAssertEqual(deadline.remainingSeconds(at: start.addingTimeInterval(14.2)), 1)
        XCTAssertFalse(deadline.isExpired(at: start.addingTimeInterval(14.999)))
        XCTAssertEqual(deadline.remainingSeconds(at: start.addingTimeInterval(15)), 0)
        XCTAssertTrue(deadline.isExpired(at: start.addingTimeInterval(15)))
        XCTAssertEqual(deadline.remainingSeconds(at: start.addingTimeInterval(120)), 0)
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("DDOffKeyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func writeOnePixelPNG(to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else {
        throw NSError(domain: "DDOffKeyTests", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "DDOffKeyTests", code: 2)
    }
}
