import AVFoundation
import CoreMedia
import Foundation

/// What a finished mp4 holds, read with `AVURLAsset` and `AVAssetReader` only (design 20.4 step 3,
/// `snapctl probe`). Independent of whatever wrote the file.
public struct VideoProbeResult: Sendable, Hashable, Codable {
    public var durationSeconds: Double
    /// Video samples in the file; nil when frames were not counted.
    public var frameCount: Int?
    /// FourCC of the video track, `avc1` or `hvc1`.
    public var codec: String?
    /// The video track's size with its transform applied.
    public var pixelSize: PixelSize?
    public var nominalFrameRate: Double?
    public var videoTrackCount: Int
    public var audioTrackCount: Int
    /// The loudest audio sample in dBFS, floored at -160 for digital silence; nil when there is no
    /// audio track or it was not measured.
    public var audioPeakDBFS: Double?
    /// The asset loads, says it is playable, and has a video track and a positive duration.
    public var playable: Bool
    public var fileBytes: Int64
    /// Why the file did not probe, when it did not.
    public var error: String?

    public init(
        durationSeconds: Double = 0,
        frameCount: Int? = nil,
        codec: String? = nil,
        pixelSize: PixelSize? = nil,
        nominalFrameRate: Double? = nil,
        videoTrackCount: Int = 0,
        audioTrackCount: Int = 0,
        audioPeakDBFS: Double? = nil,
        playable: Bool = false,
        fileBytes: Int64 = 0,
        error: String? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.codec = codec
        self.pixelSize = pixelSize
        self.nominalFrameRate = nominalFrameRate
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.audioPeakDBFS = audioPeakDBFS
        self.playable = playable
        self.fileBytes = fileBytes
        self.error = error
    }
}

public enum VideoProbe {
    /// What digital silence reports as, so the value stays a finite number in JSON.
    public static let silentDBFS = -160.0

    /// Probes `url`. Never throws: a missing or broken file probes as not playable, with `error`.
    /// - Parameters:
    ///   - countFrames: reads every video sample (no decoding) to count frames.
    ///   - measureAudio: decodes the audio until it finds a sample above the silence floor
    ///     (`AudioLevelProbe`), for the audio check.
    public static func probe(_ url: URL, countFrames: Bool = true, measureAudio: Bool = false) async -> VideoProbeResult {
        var result = VideoProbeResult(fileBytes: fileSize(url))
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            result.error = "no file at \(url.path(percentEncoded: false))"
            return result
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let (duration, isPlayable, tracks) = try await asset.load(.duration, .isPlayable, .tracks)
            let videoTracks = tracks.filter { $0.mediaType == .video }
            let audioTracks = tracks.filter { $0.mediaType == .audio }
            result.durationSeconds = duration.isNumeric ? duration.seconds : 0
            result.videoTrackCount = videoTracks.count
            result.audioTrackCount = audioTracks.count
            if let video = videoTracks.first {
                let (size, transform, formats, rate) = try await video.load(
                    .naturalSize, .preferredTransform, .formatDescriptions, .nominalFrameRate
                )
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                result.pixelSize = PixelSize(
                    width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded())
                )
                result.codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
                result.nominalFrameRate = rate > 0 ? Double(rate) : nil
                if countFrames {
                    result.frameCount = try await countSamples(of: video, in: asset)
                }
            }
            result.playable = isPlayable && !videoTracks.isEmpty && result.durationSeconds > 0
            if measureAudio, !audioTracks.isEmpty {
                // An unreadable audio track leaves the peak unknown; it does not make the video unplayable.
                do {
                    result.audioPeakDBFS = try await AudioLevelProbe.peakDBFS(of: url).map { max($0, silentDBFS) }
                } catch {
                    result.error = "audio level: \(error)"
                }
            }
        } catch {
            result.playable = false
            result.error = String(describing: error)
        }
        return result
    }

    /// A FourCC code as four characters, for example `avc1`.
    public static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func countSamples(of track: AVAssetTrack, in asset: AVAsset) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw VideoProbeError.cannotRead("cannot read the video track") }
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            throw VideoProbeError.cannotRead(String(describing: error))
        }
        var count = 0
        do {
            while let sample = try await provider.next() {
                count += sample.sampleCount
            }
        } catch {
            throw VideoProbeError.cannotRead(String(describing: error))
        }
        return count
    }

    public static func fileSize(_ url: URL) -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        } catch {
            return 0
        }
    }
}

public enum VideoProbeError: Error, Sendable, Hashable, CustomStringConvertible {
    case cannotRead(String)

    public var description: String {
        switch self {
        case .cannotRead(let message): message
        }
    }
}
