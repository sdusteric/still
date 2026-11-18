import Foundation
import SnapCore
import SwiftUI
import Testing

@testable import SnapUI

/// Text pairs of the Settings and History look (design 20.17) must hold 4.5:1 in both appearances.
@MainActor @Suite struct ThemeTests {
    private func luminance(_ color: ThemeRGBA) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    /// `top` composited over an opaque `base`.
    private func over(_ top: ThemeRGBA, _ base: ThemeRGBA) -> ThemeRGBA {
        let a = top.alpha
        return ThemeRGBA(
            red: top.red * a + base.red * (1 - a), green: top.green * a + base.green * (1 - a),
            blue: top.blue * a + base.blue * (1 - a)
        )
    }

    private func ratio(_ foreground: ThemeRGBA, _ background: ThemeRGBA) -> Double {
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    @Test func documentedContrastRatiosHold() {
        typealias C = Theme.Colors
        for dark in [false, true] {
            func pick(_ token: ThemeColor) -> ThemeRGBA { dark ? token.dark : token.light }
            let grounds: [(String, ThemeRGBA)] = [
                ("desk", pick(C.desk)), ("bar", pick(C.deskBar)), ("group", pick(C.deskGroup)),
                ("tab wash", over(pick(C.brandWash), pick(C.deskBar))),
            ]
            for (name, ground) in grounds {
                #expect(ratio(pick(C.deskText), ground) >= 4.5, "text on \(name), dark \(dark)")
                #expect(ratio(pick(C.deskText2), ground) >= 4.5, "text2 on \(name), dark \(dark)")
                #expect(ratio(pick(C.brandText), ground) >= 4.5, "brandText on \(name), dark \(dark)")
            }
            #expect(ratio(ThemeRGBA(hex: 0xFFFFFF), pick(C.brand)) >= 4.5, "white on brand, dark \(dark)")
            #expect(ratio(pick(C.brand), pick(C.desk)) >= 3, "ring on desk, dark \(dark)")
        }
    }

    @Test func theAccentButtonDrawsItsOwnBrandFill() throws {
        // A system prominent button inside the editor's NSToolbar lost its fill and left white
        // text on the light bar; this style paints the fill itself, so the host cannot drop it.
        let button = Button("Save") {}.buttonStyle(AccentFillButtonStyle())
            .padding(20).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: button)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        // Inside the button, left of the label: the brand fill, not the white ground.
        let pixel = try #require(SyntheticImages.pixel(of: image, x: 26, y: image.height / 2))
        let brand = Theme.Colors.brand.light
        #expect(abs(Double(pixel.red) / 255 - brand.red) < 0.08, "\(pixel)")
        #expect(abs(Double(pixel.blue) / 255 - brand.blue) < 0.08, "\(pixel)")
    }

    @Test func displayStylesFallBackToTheSystemFont() {
        #expect(Theme.History.titleStyle.display)
        #expect(Theme.History.titleStyle.nsFont.pointSize == 17)
    }
}
