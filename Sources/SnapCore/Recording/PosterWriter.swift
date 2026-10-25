import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// The poster of a recording (design 20.4 step 3): the frame at 0.5 s, or at half the duration
/// when that is earlier, with the track transform applied, as a PNG at the capture's DPI.
public enum PosterWriter {
    public static let preferredTime: TimeInterval = 0.5

    /// 0.5 s, or half the duration for a recording shorter than 1 s.
    public static func posterTime(duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return min(preferredTime, duration / 2)
    }

    /// The poster frame of the mp4 at `url`.
    public static func posterImage(of url: URL, duration: TimeInterval) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: posterTime(duration: duration), preferredTimescale: 600)
        return try await generator.image(at: time).image
    }

    /// The poster as PNG bytes; `scale` sets the DPI (2 writes 144 DPI).
    public static func posterPNG(of url: URL, duration: TimeInterval, scale: Double) async throws -> Data {
        try PNGWriter.data(for: try await posterImage(of: url, duration: duration), scale: scale)
    }
}
