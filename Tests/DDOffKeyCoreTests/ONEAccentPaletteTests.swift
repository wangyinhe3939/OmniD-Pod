import XCTest
@testable import DDOffKeyCore

final class ONEAccentPaletteTests: XCTestCase {
    func testVisibleColorsMatchTheFourAccentsAndCard07Spec() {
        XCTAssertEqual(ONEAccentPalette.featuredCases, [
            .mintGreen, .neonPink, .electricPurple, .fluorescentOrange
        ])
        XCTAssertEqual(ONEAccentPalette.featuredCases.map(\.accentHex), [
            0x40FFA7, 0xFF00AE, 0x8338EC, 0xFF6A00
        ])
        XCTAssertEqual(ONEAccentPalette.featuredCases.map(\.title), [
            "薄荷绿", "霓虹粉", "电光紫", "银光橙"
        ])
        XCTAssertEqual(ONEAccentPalette.featuredCases.compactMap(\.featuredNumber), [
            "01", "02", "03", "04"
        ])
        XCTAssertEqual(ONEAccentPalette.card07Cases, [
            .card07FlameRed, .card07EnergyOrange, .card07WarmOrange, .card07RadiantYellow,
            .card07LimeGreen, .card07GrassGreen, .card07LakeBlue, .card07ElectricBlue,
            .card07Violet, .card07SweetPink, .card07SoftPink, .card07PureWhite
        ])
        XCTAssertEqual(ONEAccentPalette.card07Cases.map(\.accentHex), [
            0xEB1514, 0xF7550A, 0xFB9102, 0xF6DB00,
            0x7BD10C, 0x2CBD10, 0x22C3BE, 0x0F11CF,
            0xAB2C97, 0xFC4C92, 0xF9A2AB, 0xFFFFFF
        ])
        XCTAssertEqual(ONEAccentPalette.card07Cases.map(\.title), [
            "烈焰红", "活力橙", "暖阳橙", "耀光黄",
            "青柠绿", "青草绿", "湖水蓝", "电光蓝",
            "魅力紫", "甜心粉", "柔雾粉", "纯净白"
        ])
        XCTAssertEqual(ONEAccentPalette.card07Cases.compactMap(\.featuredNumber),
                       (1...12).map { String(format: "07·%02d", $0) })
        XCTAssertEqual(ONEAccentPalette.selectableCases,
                       ONEAccentPalette.featuredCases + ONEAccentPalette.card07Cases)

        // Raw values remain available for existing stored preferences.
        XCTAssertEqual(Set(ONEAccentPalette.allCases.map(\.id)).count, 24)
    }

    func testLegacyIdentifiersResolveToNearestVisibleAccent() {
        let expected: [ONEAccentPalette: ONEAccentPalette] = [
            .fluorescentGreen: .mintGreen,
            .neonPink: .neonPink,
            .electricPurple: .electricPurple,
            .neonYellow: .fluorescentOrange,
            .electronicBlue: .mintGreen,
            .fluorescentOrange: .fluorescentOrange,
            .brightPink: .neonPink,
            .saturatedBlue: .electricPurple,
            .neonRed: .fluorescentOrange,
            .mintGreen: .mintGreen,
            .deepPurplePink: .neonPink,
            .fluorescentPinkPurple: .neonPink
        ]

        for palette in ONEAccentPalette.allCases {
            XCTAssertEqual(
                ONEAccentPalette.featuredCase(resolvingStoredID: palette.id),
                ONEAccentPalette.card07Cases.contains(palette) ? palette : expected[palette],
                palette.id
            )
        }
        XCTAssertNil(ONEAccentPalette.featuredCase(resolvingStoredID: "unknown-accent"))
        XCTAssertNil(ONEAccentPalette.featuredCase(resolvingStoredID: ""))
    }

    func testVisibleButtonTextMeetsNormalTextContrast() {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let channel = Double((hex >> shift) & 0xFF) / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        for palette in ONEAccentPalette.featuredCases {
            let a = luminance(palette.accentHex)
            let b = luminance(palette.foregroundHex)
            XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5, palette.title)
        }
    }
}
