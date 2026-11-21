import CoreGraphics
import SnapCore
@testable import SnapUI
import SwiftUI
import Testing

@MainActor
@Suite struct ScrollCaptureBarTests {
    let visible = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    let bar = CGSize(width: 420, height: 36)

    @Test func theBarSitsCenteredUnderTheAreaThenAboveThenInside() {
        let gap = Theme.ScrollCapture.barGap
        let middle = CGRect(x: 400, y: 200, width: 600, height: 400)
        let below = ScrollCaptureLayout.barFrame(area: middle, visibleFrame: visible, barSize: bar)
        #expect(below == CGRect(x: 490, y: 600 + gap, width: 420, height: 36))

        let low = CGRect(x: 400, y: 700, width: 600, height: 370)
        let above = ScrollCaptureLayout.barFrame(area: low, visibleFrame: visible, barSize: bar)
        #expect(abs(above.maxY - (700 - gap)) < 0.001)

        let tall = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        let inside = ScrollCaptureLayout.barFrame(area: tall, visibleFrame: visible, barSize: bar)
        #expect(abs(inside.maxY - (tall.maxY - gap)) < 0.001)
        #expect(visible.contains(inside))

        let edge = CGRect(x: 1800, y: 200, width: 100, height: 300)
        #expect(ScrollCaptureLayout.barFrame(area: edge, visibleFrame: visible, barSize: bar).maxX <= visible.maxX)
    }

    @Test func theBarSaysWhatToDoAndHowBigTheImageIs() {
        let model = ScrollCaptureBarModel(scale: 2)
        #expect(model.message == "Scroll down to capture more")
        #expect(model.sizeText == nil)
        model.progress = ScrollCaptureProgress(status: .growing, pixelSize: PixelSize(width: 2480, height: 13_660))
        #expect(model.message == "Scroll down to capture more")
        #expect(model.sizeText == "1240 \u{00D7} 6830")
        model.progress = ScrollCaptureProgress(status: .tooFast, pixelSize: PixelSize(width: 2480, height: 13_660))
        #expect(model.message == "Too fast. Scroll back up a little.")
        #expect(model.isWarning)
        model.progress = ScrollCaptureProgress(status: .full, pixelSize: PixelSize(width: 2480, height: 13_660))
        #expect(model.message == "Size limit reached")
    }

    @Test func theBarRendersInBothAppearances() throws {
        for dark in [false, true] {
            let model = ScrollCaptureBarModel(scale: 2)
            model.progress = ScrollCaptureProgress(status: .growing, pixelSize: PixelSize(width: 2480, height: 6000))
            let renderer = ImageRenderer(content: ScrollCaptureBar(model: model).environment(\.colorScheme, dark ? .dark : .light))
            let image = try #require(renderer.cgImage)
            #expect(image.height >= Int(Theme.ScrollCapture.barHeight))
        }
    }
}
