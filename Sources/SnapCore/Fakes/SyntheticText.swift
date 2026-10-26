import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Black text on white, drawn with Core Text, for OCR tests and `snapctl recall fixture`.
public enum SyntheticText {
    public enum Failure: Error {
        case cannotDraw
    }

    public static func png(lines: [String], size: CGSize, fontSize: CGFloat) throws -> Data {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.cannotDraw }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let lineHeight = fontSize * 1.6
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            context.textPosition = CGPoint(x: fontSize, y: CGFloat(height) - fontSize * 1.5 - CGFloat(index) * lineHeight)
            CTLineDraw(ctLine, context)
        }
        guard let image = context.makeImage() else { throw Failure.cannotDraw }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.cannotDraw
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotDraw }
        return data as Data
    }
}
