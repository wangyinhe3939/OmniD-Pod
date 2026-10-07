//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

private let homeTab = TabModel(label: "播放", icon: "music.note", view: .home)
private let shelfTab = TabModel(label: "文件暂存", icon: "tray.fill", view: .shelf)
private let extrasTab = TabModel(label: "工具", icon: "square.grid.2x2", view: .extras)

struct TabSelectionView: View {
    let showsShelf: Bool
    @Environment(\.omniDAccentTheme) private var theme
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation

    private var tabs: [TabModel] {
        showsShelf ? [homeTab, shelfTab, extrasTab] : [homeTab, extrasTab]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 24)
                    .foregroundStyle(tab.view == coordinator.currentView ? (theme.isCustom ? theme.foreground : .white) : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(theme.isCustom ? theme.accent : Color(nsColor: .secondarySystemFill))
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        .onAppear { leaveHiddenShelfIfNeeded() }
        .onChange(of: showsShelf) { _, _ in leaveHiddenShelfIfNeeded() }
    }

    private func leaveHiddenShelfIfNeeded() {
        if !showsShelf, coordinator.currentView == .shelf {
            coordinator.currentView = .home
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
