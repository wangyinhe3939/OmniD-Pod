import Foundation

enum OffKeyPermissionKind: Equatable {
    case accessibility
    case inputMonitoring

    static func firstMissing(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
    ) -> Self? {
        if !accessibilityGranted { return .accessibility }
        if !inputMonitoringGranted { return .inputMonitoring }
        return nil
    }

    var actionTitle: String {
        switch self {
        case .accessibility:
            return "打开辅助功能设置"
        case .inputMonitoring:
            return "打开输入监控设置"
        }
    }

    var systemSettingsURLs: [URL] {
        let pane = switch self {
        case .accessibility:
            "Privacy_Accessibility"
        case .inputMonitoring:
            "Privacy_ListenEvent"
        }
        return [
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
            )!,
            URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"
            )!
        ]
    }
}
