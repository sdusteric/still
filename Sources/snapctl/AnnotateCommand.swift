import CoreGraphics
import Foundation
import SnapCore

/// `snapctl annotate --in <png> --doc <json|path> --out <png> [--report]` (design 20.14): flattens
/// an `AnnotationDocument` over a PNG, the way the editor exports it. With `--report` it prints the
/// item list with step numbers and the redact regions in output pixels.
///
/// The document is JSON: `{"unit": "pt"|"px", "scale": 2, "crop": [x, y, w, h], "items": [...],
/// "delete": [index, ...], "deleteSteps": [number, ...]}`. `unit` says what the geometry is in
/// (default points of the image, top-left origin); `scale` defaults to the PNG's own; `delete`
/// removes items by their zero-based position in `items` and `deleteSteps` removes steps by the
/// number they show (1 is the first step), both resolved against the built document before any
/// is removed, as an edit session would. An item has a `kind`
/// (rectangle, arrow, text, pixelate, blur, blackout, highlight, step, freehand) and, as the kind
/// needs: `rect` [x, y, w, h], `start` and `end` [x, y], `at` [x, y] (a step's center, a text's
/// top-left corner), `points` [[x, y], ...], `color` "#RRGGBB", `width` (2, 4 or 7), `text`,
/// `fontSize`, `pill` and `filled`.
enum AnnotateCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let parsed = try CommandArguments(arguments)
            guard let inputPath = parsed.options["--in"] else { throw UsageError("missing --in <png>") }
            guard let docText = parsed.options["--doc"] else { throw UsageError("missing --doc <json>") }
            let output = try parsed.outputURL()

            let captured = try PNGReader.read(URL(filePath: inputPath).standardizedFileURL)
            let file = try loadFile(docText)
            let document = try file.makeDocument(image: captured.cgImage, imageScale: captured.scale)
            let flattened = try Flattener.flatten(document)
            try PNGWriter.write(flattened, scale: document.scale, to: output)
            if parsed.flags.contains("--report") {
                print(try PresetCommand.jsonString(Report(document: document, output: flattened)))
            }
            return 0
        } catch {
            return exitStatus(for: error)
        }
    }

    static func loadFile(_ text: String) throws -> DocumentFile {
        let data: Data
        if text.hasPrefix("{") {
            data = Data(text.utf8)
        } else {
            data = try Data(contentsOf: URL(filePath: text).standardizedFileURL)
        }
        do {
            return try JSONDecoder().decode(DocumentFile.self, from: data)
        } catch {
            throw UsageError("--doc is not a valid annotation document: \(error)")
        }
    }

    // MARK: Input

    struct DocumentFile: Decodable {
        var unit: String?
        var scale: Double?
        var crop: [Double]?
        var items: [ItemFile]
        var delete: [Int]?
        var deleteSteps: [Int]?

        func makeDocument(image: CGImage, imageScale: Double) throws -> AnnotationDocument {
            let scale = scale ?? imageScale
            // Geometry in pixels is divided down to points; widths and font sizes are always points.
            let divisor = unit == "px" ? scale : 1
            guard unit == nil || unit == "pt" || unit == "px" else { throw UsageError("unit must be pt or px") }
            var document = AnnotationDocument(image: image, scale: scale)
            for (index, file) in items.enumerated() {
                document.add(try file.makeItem(divisor: divisor, index: index))
            }
            var doomed: [UUID] = []
            for index in delete ?? [] {
                guard document.items.indices.contains(index) else { throw UsageError("delete: no item at \(index)") }
                doomed.append(document.items[index].id)
            }
            let steps = document.items.filter { $0.kind == .step }
            for number in deleteSteps ?? [] {
                guard number >= 1, number <= steps.count else { throw UsageError("deleteSteps: no step \(number)") }
                doomed.append(steps[number - 1].id)
            }
            for id in Set(doomed) { document.delete(id) }
            if let crop {
                guard crop.count == 4 else { throw UsageError("crop must be [x, y, w, h]") }
                document.crop(to: CGRect(
                    x: crop[0] / divisor, y: crop[1] / divisor, width: crop[2] / divisor, height: crop[3] / divisor
                ))
            }
            return document
        }
    }

    struct ItemFile: Decodable {
        var kind: String
        var rect: [Double]?
        var start: [Double]?
        var end: [Double]?
        var at: [Double]?
        var points: [[Double]]?
        var color: String?
        var width: Double?
        var text: String?
        var fontSize: Double?
        var pill: Bool?
        var filled: Bool?

        func makeItem(divisor: Double, index: Int) throws -> AnnotationItem {
            guard let kind = AnnotationKind(rawValue: kind) else {
                throw UsageError("item \(index): unknown kind \(self.kind)")
            }
            func point(_ values: [Double]?, _ name: String) throws -> CGPoint? {
                guard let values else { return nil }
                guard values.count == 2 else { throw UsageError("item \(index): \(name) must be [x, y]") }
                return CGPoint(x: values[0] / divisor, y: values[1] / divisor)
            }
            var color: RGBAColor?
            if let text = self.color {
                guard let parsed = RGBAColor(hex: text) else { throw UsageError("item \(index): bad color \(text)") }
                color = parsed
            }
            var item = AnnotationItem(kind: kind, start: .zero, end: .zero)
            if let color { item.color = color }
            if kind == .highlight, color == nil { item.color = AnnotateSettings.defaultHighlightColor }
            if let width { item.width = width }
            if let text { item.text = text }
            if let fontSize { item.fontSize = fontSize }
            item.pill = pill ?? false
            item.filled = filled ?? false

            switch kind {
            case .rectangle, .pixelate, .blur, .blackout, .highlight:
                if let rect {
                    guard rect.count == 4 else { throw UsageError("item \(index): rect must be [x, y, w, h]") }
                    item.start = CGPoint(x: rect[0] / divisor, y: rect[1] / divisor)
                    item.end = CGPoint(x: (rect[0] + rect[2]) / divisor, y: (rect[1] + rect[3]) / divisor)
                } else if let start = try point(start, "start"), let end = try point(end, "end") {
                    item.start = start
                    item.end = end
                } else {
                    throw UsageError("item \(index): \(kind.rawValue) needs rect or start and end")
                }
            case .arrow:
                guard let start = try point(start, "start"), let end = try point(end, "end") else {
                    throw UsageError("item \(index): arrow needs start and end")
                }
                item.start = start
                item.end = end
            case .text, .step:
                guard let origin = try point(at ?? start, "at") else {
                    throw UsageError("item \(index): \(kind.rawValue) needs at [x, y]")
                }
                item.start = origin
                item.end = origin
            case .freehand:
                guard let points, !points.isEmpty else { throw UsageError("item \(index): freehand needs points") }
                item.points = try points.map {
                    guard $0.count == 2 else { throw UsageError("item \(index): points must be [x, y] pairs") }
                    return CGPoint(x: $0[0] / divisor, y: $0[1] / divisor)
                }
                item.start = item.points[0]
                item.end = item.points[item.points.count - 1]
            }
            return item
        }
    }

    // MARK: Report

    struct PixelRect: Encodable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    struct PixelPoint: Encodable {
        var x: Double
        var y: Double
    }

    struct ItemReport: Encodable {
        var index: Int
        var kind: String
        var number: Int?
        var color: String
        var region: PixelRect?
        var center: PixelPoint?
        /// A pixel inside a step's circle clear of its number (the digit covers the center).
        var fill: PixelPoint?
        var midpoint: PixelPoint?
    }

    struct Report: Encodable {
        var width: Int
        var height: Int
        var scale: Double
        var steps: [Int]
        var items: [ItemReport]
        var redactions: [ItemReport]

        init(document: AnnotationDocument, output: CGImage) {
            width = output.width
            height = output.height
            scale = document.scale
            let numbers = document.stepNumbers
            let rect = document.outputRect
            let size = document.outputPixelSize
            func pixel(_ point: CGPoint) -> PixelPoint {
                PixelPoint(x: (point.x - rect.minX) * document.scale, y: (point.y - rect.minY) * document.scale)
            }
            var all: [ItemReport] = []
            for (index, item) in document.items.enumerated() {
                var entry = ItemReport(index: index, kind: item.kind.rawValue, color: item.color.hex)
                switch item.kind {
                case .step:
                    entry.number = numbers[item.id]
                    entry.center = pixel(item.start)
                    entry.fill = pixel(CGPoint(x: item.start.x + item.stepDiameter * 0.38, y: item.start.y))
                case .freehand:
                    entry.midpoint = FreehandPath.midpoint(of: item.points).map(pixel)
                default:
                    break
                }
                if item.kind.isRedact {
                    let region = Flattener.pixelRegion(item, document: document, size: size)
                    entry.region = PixelRect(
                        x: Int(region.minX), y: Int(region.minY), width: Int(region.width), height: Int(region.height)
                    )
                }
                all.append(entry)
            }
            items = all
            redactions = all.filter { $0.region != nil }
            steps = all.compactMap(\.number)
        }
    }
}
