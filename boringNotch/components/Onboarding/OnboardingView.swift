//
//  OnboardingView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI
import AVFoundation

enum OnboardingStep {
    case welcome
    case cameraPermission
    case calendarPermission
    case remindersPermission
    case accessibilityPermission
    case musicPermission
    case finished
}

private let calendarService = CalendarService()

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        step = .cameraPermission
                    }
                }
                .transition(.opacity)

            case .cameraPermission:
                PermissionRequestView(
                    icon: Image(systemName: "camera.fill"),
                    title: "开启相机权限",
                    description: "OmniD-Pod可以直接在刘海区域显示实时镜子，方便你快速查看自己的状态。相机只会用于实时预览，你可以随时在设置中关闭镜子功能。",
                    privacyNote: "未经你的允许不会使用相机，也不会录制或保存任何画面。",
                    onAllow: {
                        Task {
                            await requestCameraPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .calendarPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .calendarPermission
                        }
                    }
                )
                .transition(.opacity)

            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: "开启日历权限",
                    description: "OmniD-Pod可以集中显示接下来的日程，需要日历权限才能读取并展示这些安排。",
                    privacyNote: "日历数据只用于展示你的日程，不会被分享。",
                    onAllow: {
                        Task {
                                await requestCalendarPermission()
                                withAnimation(.easeInOut(duration: 0.6)) {
                                    step = .remindersPermission
                                }
                        }
                    },
                    onSkip: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .remindersPermission
                            }
                    }
                )
                .transition(.opacity)

                case .remindersPermission:
                    PermissionRequestView(
                        icon: Image(systemName: "checklist"),
                        title: "开启提醒事项权限",
                        description: "OmniD-Pod可以把已安排的提醒事项和日历日程放在一起显示，需要提醒事项权限才能读取这些内容。",
                        privacyNote: "提醒事项数据只用于展示，不会被分享。",
                        onAllow: {
                            Task {
                                await requestRemindersPermission()
                                withAnimation(.easeInOut(duration: 0.6)) {
                                    step = .accessibilityPermission
                                }
                            }
                        },
                        onSkip: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .accessibilityPermission
                            }
                        }
                    )
                    .transition(.opacity)
                
            case .accessibilityPermission:
                PermissionRequestView(
                    icon: Image(systemName: "hand.raised.fill"),
                    title: "开启辅助功能权限",
                    description: "替换系统的音量与亮度提示需要辅助功能权限。开启后，OmniD-Pod才能接收媒体键和亮度按键操作，并显示自定义提示浮层。",
                    privacyNote: "辅助功能权限只用于音量、媒体和亮度提示，不会收集或分享数据。",
                    onAllow: {
                        Task {
                            await requestAccessibilityPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(.opacity)
                
            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            BoringViewCoordinator.shared.firstLaunch = false
                            step = .finished
                        }
                    }
                )
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
            }
        }
        .frame(width: 400, height: 600)
    }

    // MARK: - Permission Request Logic

    func requestCameraPermission() async {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestCalendarPermission() async {
        _ = try? await calendarService.requestAccess(to: .event)
    }

    func requestRemindersPermission() async {
        _ = try? await calendarService.requestAccess(to: .reminder)
    }
    
    func requestAccessibilityPermission() async {
        await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
    }
}
