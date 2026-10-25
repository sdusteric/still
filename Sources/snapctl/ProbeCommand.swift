import Foundation
import SnapCore

/// `snapctl probe <file.mp4> [--json]` (design 20.14): duration, frame count, codec FourCC, pixel
/// size, audio track count and the playable flag, read with `AVURLAsset` and `AVAssetReader`
/// only, independent of the writer. Exits 0 for a playable file and 1 for one that is not.
enum ProbeCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let parsed = try CommandArguments(arguments)
            guard parsed.positional.count == 1, let path = parsed.positional.first else {
                throw UsageError("probe needs one <file.mp4>")
            }
            let url = URL(filePath: path).standardizedFileURL
            let result = await VideoProbe.probe(url)
            if parsed.json {
                print(try RecordCommand.jsonString(ProbeOutput(file: url.path(percentEncoded: false), result)))
            } else {
                print(describe(result))
            }
            return result.playable ? 0 : 1
        } catch {
            return exitStatus(for: error)
        }
    }

    /// `VideoProbeResult` with the file path, as `probe --json` and `record --json` print it.
    struct ProbeOutput: Encodable {
        var file: String
        var durationSeconds: Double
        var frameCount: Int?
        var codec: String?
        var width: Int?
        var height: Int?
        var pixelSize: PixelSize?
        var nominalFrameRate: Double?
        var videoTrackCount: Int
        var audioTrackCount: Int
        var playable: Bool
        var fileBytes: Int64
        var error: String?

        init(file: String, _ result: VideoProbeResult) {
            self.file = file
            durationSeconds = result.durationSeconds
            frameCount = result.frameCount
            codec = result.codec
            width = result.pixelSize?.width
            height = result.pixelSize?.height
            pixelSize = result.pixelSize
            nominalFrameRate = result.nominalFrameRate
            videoTrackCount = result.videoTrackCount
            audioTrackCount = result.audioTrackCount
            playable = result.playable
            fileBytes = result.fileBytes
            error = result.error
        }
    }

    static func describe(_ result: VideoProbeResult) -> String {
        let size = result.pixelSize.map(\.description) ?? "-"
        let frames = result.frameCount.map(String.init) ?? "-"
        var line = "\(result.codec ?? "-") \(size) \(String(format: "%.3f", result.durationSeconds)) s, \(frames) frames, "
            + "\(result.audioTrackCount) audio tracks, \(result.playable ? "playable" : "not playable")"
        if let error = result.error { line += " (\(error))" }
        return line
    }
}
