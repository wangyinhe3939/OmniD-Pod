import SwiftUI

struct OffKeyCleaningView: View {
    @ObservedObject var controller: OffKeyCleaningController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 24))
                    .foregroundStyle(controller.isCleaning ? .yellow : .primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.isCleaning ? "\(timeText(controller.remainingSeconds)) 后恢复" : "键盘清洁")
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    Text("只锁定键盘，鼠标与触控板可用")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if controller.isCleaning {
                ProgressView(value: controller.progress)
                    .accessibilityLabel("剩余时间")
                    .accessibilityValue(timeText(controller.remainingSeconds))
            } else {
                Picker("持续时间", selection: $controller.selectedDuration) {
                    Text("15 秒").tag(15)
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("3 分钟").tag(180)
                }.pickerStyle(.segmented).omniDSegmentedContrast().labelsHidden()
            }
            Button {
                if controller.isCleaning { controller.stopCleaning() }
                else {
                    guard OffKeyWindowCoordinator.shared.hideToolWindowsForCleaning() else { return }
                    controller.startCleaning()
                }
            } label: {
                Label(controller.isCleaning ? "立即恢复键盘" : "开始清洁", systemImage: controller.isCleaning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OmniDPodPrimaryButtonStyle())
            .disabled(!controller.isCleaning && !controller.hasPermissions)

            if !controller.isCleaning {
                HStack {
                    Text(controller.hasPermissions ? "权限已就绪" : "需允许辅助功能与输入监控")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("设置…") { SettingsWindowController.shared.showPrivacySettings() }
                }.font(.system(size: 11))
            }
            if let message = controller.lastErrorMessage {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(minWidth: 360, maxWidth: .infinity, minHeight: 230, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { controller.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
        }
    }

    private func timeText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
