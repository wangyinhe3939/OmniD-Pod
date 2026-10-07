//
//  SoftwareUpdater.swift
//  boringNotch
//
//  Created by Richard Kunkli on 09/08/2024.
//

import Foundation
import SwiftUI

@MainActor
final class OriginalVersionChecker: ObservableObject {
    static let shared = OriginalVersionChecker()
    private static let upstreamBaseVersion = "2.7.3"

    @Published private(set) var isChecking = false

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/TheBoredTeam/boring.notch/releases/latest")!
            )
            request.setValue("DD-Notch-Version-Checker", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let productVersion = Bundle.main.releaseVersionNumber?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? "未知"
            let currentVersion = Self.upstreamBaseVersion
            let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let hasNewVersion = currentVersion.compare(latestVersion, options: .numeric) == .orderedAscending

            let alert = NSAlert()
            if hasNewVersion {
                alert.messageText = "发现原版新版本 " + release.tagName
                alert.informativeText = "OmniD-Pod " + productVersion + " 当前基于原版 " + currentVersion + "。为避免覆盖中文定制，应用不会自动安装原版；你可以先查看发布说明。"
                alert.addButton(withTitle: "查看发布说明")
                alert.addButton(withTitle: "稍后")
                style(alert)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.htmlURL)
                }
            } else {
                alert.messageText = "当前已基于最新原版"
                alert.informativeText = "OmniD-Pod " + productVersion + " 的开源底座 " + currentVersion + " 已与原版最新版本 " + release.tagName + " 对齐。"
                alert.addButton(withTitle: "好")
                style(alert)
                alert.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = "请检查网络后再试。\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "好")
            style(alert)
            alert.runModal()
        }
    }

    private func style(_ alert: NSAlert) {
        OmniDWorkspaceNotice.style(alert)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checker = OriginalVersionChecker.shared

    var body: some View {
        Button(checker.isChecking ? "正在检查…" : "检查原版新版本…") {
            Task {
                await checker.checkForUpdates()
            }
        }
        .disabled(checker.isChecking)
    }
}
