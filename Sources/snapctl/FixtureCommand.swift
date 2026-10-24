import Foundation
import SnapCore

/// `snapctl gen-fixture`: writes one of the synthetic test inputs (SyntheticFixture) as a PNG at its DPI.
enum FixtureCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let parsed = try CommandArguments(arguments)
            let known = SyntheticFixture.allCases.map(\.rawValue).joined(separator: ", ")
            guard let name = parsed.positional.first else { throw UsageError("gen-fixture needs a name (\(known))") }
            guard let fixture = SyntheticFixture(rawValue: name) else {
                throw UsageError("unknown fixture \(name) (\(known))")
            }
            let url = try parsed.outputURL()
            guard let image = fixture.makeImage() else { throw FixtureError.cannotRender(name) }
            try PNGWriter.write(image, scale: fixture.scale, to: url)
            return 0
        } catch {
            return exitStatus(for: error)
        }
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case cannotRender(String)

        var description: String {
            switch self {
            case .cannotRender(let name): "cannot render fixture \(name)"
            }
        }
    }
}
