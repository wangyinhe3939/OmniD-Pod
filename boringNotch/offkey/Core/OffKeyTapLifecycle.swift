import Foundation

enum OffKeyTapMode: Equatable {
    case idle
    case mediaKeys
    case keyboardCleaning
}

struct OffKeyTapLifecycle: Equatable {
    private(set) var mode: OffKeyTapMode = .idle
    private(set) var mediaRequested = false

    mutating func setMediaRequested(_ requested: Bool) {
        mediaRequested = requested
        guard mode != .keyboardCleaning else { return }
        mode = requested ? .mediaKeys : .idle
    }

    mutating func beginCleaning() {
        mode = .keyboardCleaning
    }

    mutating func finishCleaning() {
        guard mode == .keyboardCleaning else { return }
        mode = mediaRequested ? .mediaKeys : .idle
    }

    mutating func installationFailed(for expectedMode: OffKeyTapMode) {
        guard mode == expectedMode else { return }
        mode = .idle
    }

    mutating func stopAll() {
        mediaRequested = false
        mode = .idle
    }
}

enum OffKeyCleaningEventKind: Equatable {
    case keyDown
    case keyUp
    case flagsChanged
    case systemDefined(subtype: Int?)
    case pointer
    case other
}

enum OffKeyCleaningEventPolicy {
    static func shouldSuppress(_ event: OffKeyCleaningEventKind) -> Bool {
        switch event {
        case .keyDown, .keyUp, .flagsChanged:
            return true
        case .systemDefined(subtype: 8):
            return true
        case .systemDefined, .pointer, .other:
            return false
        }
    }
}

struct OffKeyCleaningDeadline: Equatable {
    let end: Date

    init(duration: TimeInterval, now: Date = Date()) {
        end = now.addingTimeInterval(duration)
    }

    func remainingSeconds(at now: Date = Date()) -> Int {
        max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    }

    func isExpired(at now: Date = Date()) -> Bool {
        end <= now
    }
}

struct OffKeyScanRequestGate: Equatable {
    private(set) var latestGeneration = 0
    private(set) var runningGeneration: Int?

    mutating func request() -> Int? {
        latestGeneration += 1
        guard runningGeneration == nil else { return nil }
        runningGeneration = latestGeneration
        return latestGeneration
    }

    mutating func finish(_ generation: Int) -> Int? {
        guard runningGeneration == generation else { return nil }
        runningGeneration = nil
        guard generation != latestGeneration else { return nil }
        runningGeneration = latestGeneration
        return latestGeneration
    }
}
