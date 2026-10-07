import ApplicationServices
import AppKit
import Combine
import Foundation

enum OffKeyCleaningError: LocalizedError {
    case permissionsRequired
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionsRequired:
            return "需要同时允许辅助功能和输入监控，才会进入清洁模式。"
        case .eventTapUnavailable:
            return "macOS 没有创建键盘拦截；没有锁住任何输入。"
        }
    }
}

@MainActor
final class OffKeyCleaningController: ObservableObject {
    static let shared = OffKeyCleaningController()
    static let allowedDurations = [15, 30, 60, 180]

    @Published private(set) var isCleaning = false
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var hasPermissions = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var permissionMessage: String?
    @Published var lastErrorMessage: String?
    @Published var selectedDuration: Int {
        didSet {
            guard Self.allowedDurations.contains(selectedDuration) else {
                selectedDuration = 30
                return
            }
            UserDefaults.standard.set(selectedDuration, forKey: durationKey)
        }
    }

    private let durationKey = "DDOffKey.defaultCleaningDuration"
    private var timer: Timer?
    private var deadline: OffKeyCleaningDeadline?
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var applicationObserverTokens: [NSObjectProtocol] = []

    private init() {
        let stored = UserDefaults.standard.integer(forKey: durationKey)
        selectedDuration = Self.allowedDurations.contains(stored) ? stored : 30
        refreshPermissions()
        registerSafetyObservers()
    }

    var progress: Double {
        guard selectedDuration > 0 else { return 0 }
        return Double(remainingSeconds) / Double(selectedDuration)
    }

    var nextMissingPermission: OffKeyPermissionKind? {
        OffKeyPermissionKind.firstMissing(
            accessibilityGranted: accessibilityGranted,
            inputMonitoringGranted: inputMonitoringGranted
        )
    }

    var permissionActionTitle: String {
        nextMissingPermission?.actionTitle ?? "权限已就绪"
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        hasPermissions = accessibilityGranted && inputMonitoringGranted
        permissionMessage = hasPermissions ? "辅助功能与输入监控均已允许。" : nil
    }

    func requestPermissions() {
        refreshPermissions()
        guard let permission = nextMissingPermission else { return }
        MediaKeyInterceptor.shared.requestKeyboardCleaningPermission(permission)
        permissionMessage = nil
        openSystemSettings(for: permission)
    }

    private func openSystemSettings(for permission: OffKeyPermissionKind) {
        if permission.systemSettingsURLs.contains(where: NSWorkspace.shared.open) {
            permissionMessage = "请在系统设置中允许此 App；返回后会自动刷新。"
            return
        }

        let privacyURLs = [
            URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
            )!,
            URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        ]
        if privacyURLs.contains(where: NSWorkspace.shared.open) {
            permissionMessage = "已打开隐私与安全性，请进入对应权限并允许此 App。"
        } else {
            permissionMessage = "系统设置未能打开，请手动进入“隐私与安全性”。"
        }
    }

    func startCleaning() {
        guard !isCleaning else { return }
        refreshPermissions()
        do {
            try MediaKeyInterceptor.shared.beginKeyboardCleaning()
            let deadline = OffKeyCleaningDeadline(duration: TimeInterval(selectedDuration))
            self.deadline = deadline
            remainingSeconds = deadline.remainingSeconds()
            isCleaning = true
            lastErrorMessage = nil
            scheduleTimer()
        } catch {
            MediaKeyInterceptor.shared.endKeyboardCleaning()
            lastErrorMessage = error.localizedDescription
            isCleaning = false
            remainingSeconds = 0
            deadline = nil
        }
    }

    func stopCleaning() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        MediaKeyInterceptor.shared.endKeyboardCleaning()
        isCleaning = false
        remainingSeconds = 0
    }

    func prepareForTermination() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        isCleaning = false
        remainingSeconds = 0
        MediaKeyInterceptor.shared.stopAllEventInterception()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reconcileDeadline()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func reconcileDeadline(now: Date = Date()) {
        guard isCleaning, let deadline else { return }
        if deadline.isExpired(at: now) {
            stopCleaning()
            return
        }
        remainingSeconds = deadline.remainingSeconds(at: now)
    }

    private func registerSafetyObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stopCleaning()
                }
            }
        )
        workspaceObserverTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermissions()
                    self?.reconcileDeadline()
                }
            }
        )
        applicationObserverTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermissions()
                    self?.reconcileDeadline()
                }
            }
        )
    }
}
