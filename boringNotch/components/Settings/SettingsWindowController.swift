//
//  SettingsWindowController.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-14.
//

import AppKit
import SwiftUI
import Defaults

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OmniDWorkspaceSettingsSize.width, height: OmniDWorkspaceSettingsSize.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = "OmniD-Pod · 设置"
        window.appearance = nil
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        
        // Make it behave like a regular app window with proper Spaces support
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        
        // Ensure proper window behavior
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        // Configure window to be a standard document-style window
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("OmniDWorkspace.Settings")
        
        // Create the SwiftUI content
        let settingsView = SettingsView().workspacePreferences()
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.sizingOptions = []
        window.contentView = hostingView
        OmniDWorkspacePreferences.shared.style(window)
        
        // Handle window closing
        window.delegate = self
    }
    
    func showWindow() {
        OffKeyWindowCoordinator.shared.prepareForSettings()
        // Set app to regular mode first
        NSApp.setActivationPolicy(.regular)
        OmniDPodAppIcon.applyStored()
        
        // If window is already visible, bring it to front properly
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            return
        }
        
        // Show the window with proper ordering
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        
        // Activate the app and ensure window gets focus
        NSApp.activate(ignoringOtherApps: true)
        
        // Force window to front after activation
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }
    
    func showPrivacySettings() {
        OmniDPodSettingsNavigation.shared.selection = .privacy
        showWindow()
    }

    func showAppearanceSettings() {
        OmniDPodSettingsNavigation.shared.selection = .appearance
        showWindow()
    }

    override func close() {
        super.close()
        relinquishFocus()
    }
    
    private func relinquishFocus() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocus()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure app is in regular mode when window becomes key
        NSApp.setActivationPolicy(.regular)
        OmniDPodAppIcon.applyStored()
    }
    
    func windowDidResignKey(_ notification: Notification) {
    }
    
}
