//
//  ApplicationRelauncher.swift
//  boringNotch
//
//  Created by Corentin132 on 03/10/2025.
//

import AppKit

enum ApplicationRelauncher {
    @MainActor private static var pendingApplicationURL: URL?

    @MainActor
    static func restart() {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        guard appURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: appURL.path)
        else { return }

        pendingApplicationURL = appURL
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    static func cancelPendingRestart() {
        pendingApplicationURL = nil
    }

    @MainActor
    static func launchReplacementIfRequested() {
        guard let appURL = pendingApplicationURL else { return }
        pendingApplicationURL = nil

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: configuration,
            completionHandler: nil
        )
    }
}
