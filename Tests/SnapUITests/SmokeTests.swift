import AppKit
import SnapCore
import SnapUI
import Testing

@Suite struct SnapUISmokeTests {
    @Test func colorTokensDifferBetweenLightAndDark() {
        #expect(Theme.Colors.window.cgColor(dark: false) != Theme.Colors.window.cgColor(dark: true))
        #expect(Theme.Colors.canvas.light == ThemeRGBA(hex: 0xE6E6EA))
        #expect(Theme.Colors.canvas.dark == ThemeRGBA(hex: 0x141416))
        #expect(Theme.Colors.dim.light == Theme.Colors.dim.dark)
        #expect(Theme.Colors.dim.light.alpha == 0.38)
    }

    @Test func appearanceDetection() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        #expect(ThemeColor.isDark(dark))
        #expect(!ThemeColor.isDark(light))
        #expect(Theme.Colors.sidebar.cgColor(for: dark) == ThemeRGBA(hex: 0x242427).cgColor)
    }

    @Test func sizeTokensMatchTheDesign() {
        #expect(Theme.QuickAccess.cardRadius == 16)
        #expect(Theme.QuickAccess.thumbnailRadius == Theme.QuickAccess.cardRadius - Theme.QuickAccess.cardPadding)
        #expect(Theme.Overlay.magnifierDiameter == 120)
        #expect(Theme.BackgroundEditor.windowSize == CGSize(width: 920, height: 640))
        #expect(Theme.Settings.width == 480)
        #expect(Theme.Typography.chip.nsFont.pointSize == 11)
    }
}
