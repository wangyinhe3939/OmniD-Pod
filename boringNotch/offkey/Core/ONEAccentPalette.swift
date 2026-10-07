import Foundation

/// Persisted palette identifiers. Legacy cases remain so existing preferences can be resolved.
public enum ONEAccentPalette: String, CaseIterable, Identifiable {
    case fluorescentGreen, neonPink, electricPurple, neonYellow
    case electronicBlue, fluorescentOrange, brightPink, saturatedBlue
    case neonRed, mintGreen, deepPurplePink, fluorescentPinkPurple
    case card07FlameRed, card07EnergyOrange, card07WarmOrange, card07RadiantYellow
    case card07LimeGreen, card07GrassGreen, card07LakeBlue, card07ElectricBlue
    case card07Violet, card07SweetPink, card07SoftPink, card07PureWhite

    public var id: String { rawValue }

    public static let featuredCases: [Self] = [
        .mintGreen,
        .neonPink,
        .electricPurple,
        .fluorescentOrange
    ]

    public static let card07Cases: [Self] = [
        .card07FlameRed, .card07EnergyOrange, .card07WarmOrange, .card07RadiantYellow,
        .card07LimeGreen, .card07GrassGreen, .card07LakeBlue, .card07ElectricBlue,
        .card07Violet, .card07SweetPink, .card07SoftPink, .card07PureWhite
    ]

    public static let selectableCases = featuredCases + card07Cases

    /// Resolves current card colors and legacy stored identifiers without changing past choices.
    public static func featuredCase(resolvingStoredID storedID: String) -> Self? {
        if let palette = Self(rawValue: storedID), card07Cases.contains(palette) {
            return palette
        }
        switch storedID {
        case Self.mintGreen.rawValue,
             Self.fluorescentGreen.rawValue,
             Self.electronicBlue.rawValue:
            return .mintGreen
        case Self.neonPink.rawValue,
             Self.brightPink.rawValue,
             Self.deepPurplePink.rawValue,
             Self.fluorescentPinkPurple.rawValue:
            return .neonPink
        case Self.electricPurple.rawValue,
             Self.saturatedBlue.rawValue:
            return .electricPurple
        case Self.fluorescentOrange.rawValue,
             Self.neonYellow.rawValue,
             Self.neonRed.rawValue:
            return .fluorescentOrange
        default:
            return nil
        }
    }

    public var featuredNumber: String? {
        if let index = Self.featuredCases.firstIndex(of: self) {
            return String(format: "%02d", index + 1)
        }
        if let index = Self.card07Cases.firstIndex(of: self) {
            return String(format: "07·%02d", index + 1)
        }
        return nil
    }

    public var title: String {
        switch self {
        case .fluorescentGreen: "荧光绿"
        case .neonPink: "霓虹粉"
        case .electricPurple: "电光紫"
        case .neonYellow: "霓虹黄"
        case .electronicBlue: "电子蓝"
        case .fluorescentOrange: "银光橙"
        case .brightPink: "亮粉红"
        case .saturatedBlue: "高饱和蓝"
        case .neonRed: "霓虹红"
        case .mintGreen: "薄荷绿"
        case .deepPurplePink: "深紫粉"
        case .fluorescentPinkPurple: "荧光粉紫"
        case .card07FlameRed: "烈焰红"
        case .card07EnergyOrange: "活力橙"
        case .card07WarmOrange: "暖阳橙"
        case .card07RadiantYellow: "耀光黄"
        case .card07LimeGreen: "青柠绿"
        case .card07GrassGreen: "青草绿"
        case .card07LakeBlue: "湖水蓝"
        case .card07ElectricBlue: "电光蓝"
        case .card07Violet: "魅力紫"
        case .card07SweetPink: "甜心粉"
        case .card07SoftPink: "柔雾粉"
        case .card07PureWhite: "纯净白"
        }
    }

    public var accentHex: UInt32 {
        switch self {
        case .fluorescentGreen: 0x39FF14
        case .neonPink: 0xFF00AE
        case .electricPurple: 0x8338EC
        case .neonYellow: 0xFFEB00
        case .electronicBlue: 0x00FFFB
        case .fluorescentOrange: 0xFF6A00
        case .brightPink: 0xFF2BD6
        case .saturatedBlue: 0x0036FF
        case .neonRed: 0xFF1637
        case .mintGreen: 0x40FFA7
        case .deepPurplePink: 0xFF19E7
        case .fluorescentPinkPurple: 0xFF6BFF
        case .card07FlameRed: 0xEB1514
        case .card07EnergyOrange: 0xF7550A
        case .card07WarmOrange: 0xFB9102
        case .card07RadiantYellow: 0xF6DB00
        case .card07LimeGreen: 0x7BD10C
        case .card07GrassGreen: 0x2CBD10
        case .card07LakeBlue: 0x22C3BE
        case .card07ElectricBlue: 0x0F11CF
        case .card07Violet: 0xAB2C97
        case .card07SweetPink: 0xFC4C92
        case .card07SoftPink: 0xF9A2AB
        case .card07PureWhite: 0xFFFFFF
        }
    }

    public var foregroundHex: UInt32 {
        switch self {
        case .electricPurple, .saturatedBlue,
             .card07FlameRed, .card07GrassGreen, .card07ElectricBlue,
             .card07Violet, .card07SweetPink: 0xFFFFFF
        case .fluorescentPinkPurple: 0x1A0033
        default: 0x0B0B0B
        }
    }

    public var hexLabel: String { String(format: "#%06X", accentHex) }
}
