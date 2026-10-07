//
//  MediaKeyInterceptor.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-23.

import Foundation
@preconcurrency import AppKit
import ApplicationServices
import Defaults
import AVFoundation
import Combine

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

@MainActor
final class MediaKeyInterceptor: ObservableObject {
    static let shared = MediaKeyInterceptor()
    
    private enum NXKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case keyboardBrightnessUp = 21
        case keyboardBrightnessDown = 22
    }
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let step: Float = 1.0 / 16.0
    private var audioPlayer: AVAudioPlayer?
    private var lifecycle = OffKeyTapLifecycle()
    private var mediaStartGate = OffKeyMediaStartGate()
    @Published private(set) var isMediaTapActive = false
    @Published private(set) var mediaStatus = "未启用"

    var tapMode: OffKeyTapMode { lifecycle.mode }
    
    private init() {}
    
    // MARK: - Main app accessibility
    
    func requestAccessibilityAuthorization() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
        _ = OffKeyPermissionKind.accessibility.systemSettingsURLs.contains(where: NSWorkspace.shared.open)
    }
    
    func ensureAccessibilityAuthorization(promptIfNeeded: Bool = false) async -> Bool {
        await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: promptIfNeeded)
    }
    
    // MARK: - Event Tap
    
    func start(promptIfNeeded: Bool = false) async {
        let mediaRequested = Defaults[.hudReplacement]
        lifecycle.setMediaRequested(mediaRequested)
        guard let generation = mediaStartGate.requestStart(desired: mediaRequested) else {
            stop()
            return
        }
        guard tapMode != .keyboardCleaning else {
            mediaStatus = "键盘清洁期间暂停系统提示，结束后自动恢复。"
            return
        }
        
        // Check accessibility authorization
        let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        guard !Task.isCancelled, Defaults[.hudReplacement], tapMode != .keyboardCleaning else { return }
        if !authorized {
            tearDownTap()
            if promptIfNeeded {
                let granted = await ensureAccessibilityAuthorization(promptIfNeeded: true)
                guard canFinishMediaStart(generation) else { return }
                guard granted else {
                    lifecycle.installationFailed(for: .mediaKeys)
                    mediaStatus = "等待辅助功能授权；允许后返回 App，会自动启用。"
                    return
                }
            } else {
                lifecycle.installationFailed(for: .mediaKeys)
                mediaStatus = "等待辅助功能授权；允许后返回 App，会自动启用。"
                return
            }
        }

        guard eventTap == nil else { return }
        guard canFinishMediaStart(generation) else { return }
        if !installTap(for: .mediaKeys) {
            lifecycle.installationFailed(for: .mediaKeys)
            mediaStatus = "系统按键监听未建立；仍使用系统提示。请刷新状态，必要时重新启动 App。"
        }
    }
    
    func stop() {
        lifecycle.setMediaRequested(false)
        mediaStartGate.updateDesired(false)
        mediaStatus = "未启用"
        guard tapMode != .keyboardCleaning else { return }
        tearDownTap()
    }

    func beginKeyboardCleaning() throws {
        guard hasKeyboardCleaningPermissions else {
            throw OffKeyCleaningError.permissionsRequired
        }
        guard tapMode != .keyboardCleaning else { return }

        let mediaRequested = Defaults[.hudReplacement]
        lifecycle.setMediaRequested(mediaRequested)
        mediaStartGate.updateDesired(mediaRequested)
        tearDownTap()
        lifecycle.beginCleaning()
        guard installTap(for: .keyboardCleaning) else {
            lifecycle.finishCleaning()
            if tapMode == .mediaKeys, !installTap(for: .mediaKeys) {
                lifecycle.installationFailed(for: .mediaKeys)
            }
            throw OffKeyCleaningError.eventTapUnavailable
        }
        mediaStatus = "键盘清洁期间暂停系统提示，结束后自动恢复。"
    }

    func endKeyboardCleaning() {
        guard tapMode == .keyboardCleaning else { return }
        tearDownTap()
        lifecycle.finishCleaning()
        if tapMode == .mediaKeys, !installTap(for: .mediaKeys) {
            lifecycle.installationFailed(for: .mediaKeys)
            mediaStatus = "系统按键监听未恢复；仍使用系统提示。请刷新状态。"
        }
    }

    func stopAllEventInterception() {
        tearDownTap()
        lifecycle.stopAll()
        mediaStartGate.updateDesired(false)
    }

    var hasKeyboardCleaningPermissions: Bool {
        AXIsProcessTrusted()
            && CGPreflightListenEventAccess()
    }

    func requestKeyboardCleaningPermission(_ permission: OffKeyPermissionKind) {
        switch permission {
        case .accessibility:
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    static func suppressesEventDuringCleaning(
        type: CGEventType,
        systemDefinedSubtype: Int? = nil
    ) -> Bool {
        let event: OffKeyCleaningEventKind
        switch type {
        case .keyDown: event = .keyDown
        case .keyUp: event = .keyUp
        case .flagsChanged: event = .flagsChanged
        case kSystemDefinedEventType: event = .systemDefined(subtype: systemDefinedSubtype)
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .scrollWheel:
            event = .pointer
        default:
            event = .other
        }
        return OffKeyCleaningEventPolicy.shouldSuppress(event)
    }

    @discardableResult
    private func installTap(for mode: OffKeyTapMode) -> Bool {
        guard eventTap == nil else { return tapMode == mode }
        let mask: CGEventMask
        let tapLocation: CGEventTapLocation
        switch mode {
        case .idle:
            return true
        case .mediaKeys:
            mask = CGEventMask(1) << kSystemDefinedEventType.rawValue
            tapLocation = .cgSessionEventTap
        case .keyboardCleaning:
            mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                | (CGEventMask(1) << kSystemDefinedEventType.rawValue)
            tapLocation = .cgSessionEventTap
        }

        eventTap = CGEvent.tapCreate(
            tap: tapLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
                let interceptor = Unmanaged<MediaKeyInterceptor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return MainActor.assumeIsolated {
                    interceptor.handleTap(type: type, event: cgEvent)
                }
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let eventTap else {
            return false
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource else {
            self.eventTap = nil
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isMediaTapActive = mode == .mediaKeys
        if isMediaTapActive { mediaStatus = "已启用，音量与亮度按键使用刘海提示。" }
        return true
    }

    private func canFinishMediaStart(
        _ generation: OffKeyMediaStartGate.Generation
    ) -> Bool {
        !Task.isCancelled
            && Defaults[.hudReplacement]
            && eventTap == nil
            && mediaStartGate.permitsInstallation(
                generation: generation,
                mode: tapMode
            )
    }

    private func tearDownTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isMediaTapActive = false
    }
    
    // MARK: - Event Handling
    
    private func handleTap(type: CGEventType, event cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        }

        if tapMode == .keyboardCleaning {
            let subtype = type == kSystemDefinedEventType
                ? NSEvent(cgEvent: cgEvent).map { Int($0.subtype.rawValue) }
                : nil
            if Self.suppressesEventDuringCleaning(
                type: type,
                systemDefinedSubtype: subtype
            ) {
                return nil
            }
            return Unmanaged.passUnretained(cgEvent)
        }
        return handleMediaEvent(cgEvent)
    }

    private func handleMediaEvent(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // Ensure the CGEvent has a valid type before converting to NSEvent
        guard cgEvent.type != .null else {
            return Unmanaged.passUnretained(cgEvent)
        }
        guard let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }
        
        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let stateByte = ((data1 & 0xFF00) >> 8)
        
        // 0xA = key down, 0xB = key up. Only handle key down.
        guard stateByte == 0xA,
              let keyType = NXKeyType(rawValue: keyCode) else {
            return Unmanaged.passUnretained(cgEvent)
        }
        
        let flags = nsEvent.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        
        // Handle option key action (without shift)
        if option && !shift {
            if handleOptionAction(for: keyType, command: command) {
                return nil
            }
        }
        
        // Handle normal key press
        handleKeyPress(keyType: keyType, option: option, shift: shift, command: command)
        return nil
    }
    
    private func handleOptionAction(for keyType: NXKeyType, command: Bool) -> Bool {
        let action = Defaults[.optionKeyAction]
        
        switch action {
        case .openSettings:
            openSystemSettings(for: keyType, command: command)
            return true
        case .showHUD:
            showHUD(for: keyType, command: command)
            return true
        case .none:
            return true
        }
    }
    
    private func prepareAudioPlayerIfNeeded() {
        guard audioPlayer == nil else { return }

        let defaultPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        if FileManager.default.fileExists(atPath: defaultPath) {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: defaultPath))
                print("🔊 [MediaKeyInterceptor] Loaded default Bezel audio from: \(defaultPath)")
            } catch {
                print("⚠️ [MediaKeyInterceptor] Failed to init AVAudioPlayer with default path \(defaultPath): \(error.localizedDescription)")
            }
        } else {
            print("⚠️ [MediaKeyInterceptor] Default bezel audio not found at: \(defaultPath)")
        }

        if let player = audioPlayer {
            player.volume = 1.0
            player.numberOfLoops = 0
            player.prepareToPlay()
        }
    }

    private func playFeedbackSound() {
        guard let feedback = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["com.apple.sound.beep.feedback"] as? Int,
              feedback == 1 else { return }

        prepareAudioPlayerIfNeeded()
        guard let player = audioPlayer else {
            print("⚠️ [MediaKeyInterceptor] No audio player available to play feedback sound")
            return
        }
        if let url = player.url {
            print("🔊 [MediaKeyInterceptor] Playing feedback sound from: \(url.path)")
        } else {
            print("🔊 [MediaKeyInterceptor] Playing feedback sound (no url available for AVAudioPlayer)")
        }
        if player.isPlaying {
            player.stop()
            player.currentTime = 0
        }
        player.play()
    }

    private func handleKeyPress(keyType: NXKeyType, option: Bool, shift: Bool, command: Bool) {
        let stepDivisor: Float = (option && shift) ? 4.0 : 1.0
        
        switch keyType {
        case .soundUp:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.increase(stepDivisor: stepDivisor)
            }
        case .soundDown:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.decrease(stepDivisor: stepDivisor)
            }
        case .mute:
            Task { @MainActor in
                VolumeManager.shared.toggleMuteAction()
            }
        case .brightnessUp, .keyboardBrightnessUp:
            let delta = step / stepDivisor
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessUp || command)
        case .brightnessDown, .keyboardBrightnessDown:
            let delta = -(step / stepDivisor)
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessDown || command)
        }
    }
    
    private func adjustBrightness(delta: Float, keyboard: Bool) {
        Task { @MainActor in
            if keyboard {
                KeyboardBacklightManager.shared.setRelative(delta: delta)
            } else {
                BrightnessManager.shared.setRelative(delta: delta)
            }
        }
    }
    
    private func showHUD(for keyType: NXKeyType, command: Bool) {
        Task { @MainActor in
            switch keyType {
            case .soundUp, .soundDown, .mute:
                let v = VolumeManager.shared.rawVolume
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(v))
            case .brightnessUp, .brightnessDown:
                if command {
                    let v = KeyboardBacklightManager.shared.rawBrightness
                    BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
                } else {
                    let v = BrightnessManager.shared.rawBrightness
                    BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(v))
                }
            case .keyboardBrightnessUp, .keyboardBrightnessDown:
                let v = KeyboardBacklightManager.shared.rawBrightness
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
            }
        }
    }
    
    private func openSystemSettings(for keyType: NXKeyType, command: Bool) {
        let urlString: String
        
        switch keyType {
        case .soundUp, .soundDown, .mute:
            urlString = "x-apple.systempreferences:com.apple.preference.sound"
        case .brightnessUp, .brightnessDown:
            if command {
                urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
            } else {
                urlString = "x-apple.systempreferences:com.apple.preference.displays"
            }
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
        }
        
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
