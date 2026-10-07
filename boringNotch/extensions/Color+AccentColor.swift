//
//  Color+AccentColor.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-24.
//

import SwiftUI
import Defaults

fileprivate struct ResolvedOmniDAccent {
    let color: NSColor
    let palette: ONEAccentPalette?
    let isCustom: Bool
}

extension NSColor {
    convenience init(oneHex: UInt32) {
        self.init(srgbRed: Double((oneHex >> 16) & 0xFF) / 255,
                  green: Double((oneHex >> 8) & 0xFF) / 255,
                  blue: Double(oneHex & 0xFF) / 255, alpha: 1)
    }

    fileprivate static var omniDGraphiteAccent: NSColor {
        NSColor(white: 0.58, alpha: 1)
    }

    fileprivate static func resolvedOmniDAccentSource(
        useCustom: Bool,
        paletteID: String?,
        data: Data?
    ) -> ResolvedOmniDAccent {
        guard useCustom else {
            return ResolvedOmniDAccent(color: omniDGraphiteAccent, palette: nil, isCustom: false)
        }

        if let paletteID {
            guard let palette = ONEAccentPalette.featuredCase(resolvingStoredID: paletteID) else {
                return ResolvedOmniDAccent(color: omniDGraphiteAccent, palette: nil, isCustom: false)
            }
            return ResolvedOmniDAccent(
                color: NSColor(oneHex: palette.accentHex),
                palette: palette,
                isCustom: true
            )
        }

        if let data,
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return ResolvedOmniDAccent(color: color, palette: nil, isCustom: true)
        }

        return ResolvedOmniDAccent(color: omniDGraphiteAccent, palette: nil, isCustom: false)
    }

    static func resolvedOmniDAccent(useCustom: Bool, paletteID: String?, data: Data?) -> NSColor {
        resolvedOmniDAccentSource(useCustom: useCustom, paletteID: paletteID, data: data).color
    }

    static var effectiveAccent: NSColor {
        resolvedOmniDAccent(useCustom: Defaults[.useCustomAccentColor],
                           paletteID: Defaults[.oneAccentPaletteID], data: Defaults[.customAccentColorData])
    }

    static var effectiveAccentBackground: NSColor {
        effectiveAccent.withAlphaComponent(0.25)
    }
}

extension Color {
    static var effectiveAccent: Color { Color(nsColor: .effectiveAccent) }
    static var effectiveAccentBackground: Color { effectiveAccent.opacity(0.25) }
}

struct OmniDAccentTheme {
    var isCustom = false
    var accent = OmniDPodStyle.accent
    var foreground = Color.black
    var readableAccent = Color.white

    init(useCustom: Bool = false, paletteID: String? = nil, data: Data? = nil) {
        let source = NSColor.resolvedOmniDAccentSource(
            useCustom: useCustom,
            paletteID: paletteID,
            data: data
        )
        isCustom = source.isCustom
        let base = source.color
        accent = Color(nsColor: base)
        let rgb = base.usingColorSpace(.sRGB) ?? base
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        if let palette = source.palette {
            foreground = Color(nsColor: NSColor(oneHex: palette.foregroundHex))
        } else {
            foreground = luminance > 0.179 ? .black : .white
        }
        readableAccent = luminance < 0.18
            ? Color(nsColor: base.blended(withFraction: 0.4, of: .white) ?? base) : accent
    }

    var selectionBackground: Color { OmniDPodStyle.surface }
}

extension EnvironmentValues {
    @Entry var omniDAccentTheme = OmniDAccentTheme()
}

private struct OmniDAccentThemeModifier: ViewModifier {
    @Default(.useCustomAccentColor) private var useCustom
    @Default(.customAccentColorData) private var data
    @Default(.oneAccentPaletteID) private var paletteID

    func body(content: Content) -> some View {
        let theme = OmniDAccentTheme(useCustom: useCustom, paletteID: paletteID, data: data)
        content.environment(\.omniDAccentTheme, theme).tint(theme.accent).accentColor(theme.accent)
    }
}

extension View {
    func omniDAccentTheme() -> some View { modifier(OmniDAccentThemeModifier()) }
}

private struct OmniDSegmentedContrastModifier: ViewModifier {
    @Environment(\.omniDAccentTheme) private var theme

    func body(content: Content) -> some View {
        content.tint(theme.accent).accentColor(theme.accent)
    }
}

extension View {
    func omniDSegmentedContrast() -> some View { modifier(OmniDSegmentedContrastModifier()) }
}
