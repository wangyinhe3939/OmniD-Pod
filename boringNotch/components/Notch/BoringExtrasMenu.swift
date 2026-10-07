//
//  BoringExtrasMenu.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import SwiftUI
import AppKit

@objc(DDNativeSlotFactory) @MainActor
protocol DDNativeSlotFactory: AnyObject {
    static func makeFactory() -> DDNativeSlotFactory
    func makePanel() -> NSPanel
    func makeSettingsController() -> NSViewController
    func makeAttentionController() -> NSViewController
}

@MainActor
final class DDOptionalNativeSlot {
    static let shared = DDOptionalNativeSlot()
    let factory: DDNativeSlotFactory?

    private init() {
        factory = (NSClassFromString("DDOmniRouterFactory") as? DDNativeSlotFactory.Type)?.makeFactory()
    }
}

struct DDNativeSlotSettings: NSViewControllerRepresentable {
    let factory: DDNativeSlotFactory
    func makeNSViewController(context: Context) -> NSViewController { factory.makeSettingsController() }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

struct DDNativeSlotAttention: NSViewControllerRepresentable {
    let factory: DDNativeSlotFactory
    func makeNSViewController(context: Context) -> NSViewController { factory.makeAttentionController() }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

struct BoringLargeButtons: View {
    var action: () -> Void
    var icon: Image
    var title: String
    var body: some View {
        Button (
            action:action,
            label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12.0).fill(.black).frame(width: 70, height: 70)
                    VStack(spacing: 8) {
                        icon.resizable()
                            .aspectRatio(contentMode: .fit).frame(width:20)
                        Text(title).font(.body)
                    }
                }
            }).buttonStyle(PlainButtonStyle()).shadow(color: .black.opacity(0.5), radius: 10)
    }
}

@MainActor struct BoringExtrasMenu: View {
    @ObservedObject var vm: BoringViewModel
    var body: some View {
        OmniDPodNotchActions()
            .overlay(alignment: .topTrailing) {
                if let factory = DDOptionalNativeSlot.shared.factory {
                    DDNativeSlotAttention(factory: factory).frame(width: 20, height: 20)
                }
            }
    }
}


#Preview {
    BoringExtrasMenu(vm: .init())
}
