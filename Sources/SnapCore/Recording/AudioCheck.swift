import AVFoundation
import CoreMedia
import Foundation

/// Whether a finished recording carries the audio it asked for (design 20.6, audio check). Stored
/// in `item.json` and shown on the video card, so a silent file is noticed before it is shared.
public enum AudioCheck: String, Sendable, Hashable, Codable, CaseIterable {
    /// Audio was asked for and the file has a track with sound in it.
    case captured
    /// Audio was asked for and the file has no audio track.
    case noTrack
    /// The microphone was asked for and the whole file stays below the silence floor.
    case microphoneSilent
    /// Only system audio was asked for and the whole file stays below the silence floor.
    case systemSilent

    /// Anything quieter than this for the whole file counts as silent.
    public static let silenceFloorDBFS = -60.0

    /// The card's warning text, nil when the audio is fine.
    public var warning: String? {
        switch self {
        case .captured: nil
        case .noTrack: "No audio track"
        case .microphoneSilent: "Microphone silent"
        case .systemSilent: "System audio silent"
        }
    }

    /// The check for a file. Nil when no audio was asked for: a silent screen demo is normal.
    /// - Parameters:
    ///   - requested: the audio sources the recording asked for (the microphone is left out when
    ///     access was off, since the card already says "No microphone").
    ///   - audioTrackCount: audio tracks in the file.
    ///   - peakDBFS: the loudest sample of the file in dBFS, nil when it was not measured.
    public static func evaluate(requested: [AudioSource], audioTrackCount: Int, peakDBFS: Double?) -> AudioCheck? {
        guard !requested.isEmpty else { return nil }
        guard audioTrackCount > 0 else { return .noTrack }
        guard let peakDBFS, peakDBFS < silenceFloorDBFS else { return .captured }
        return requested.contains(.microphone) ? .microphoneSilent : .systemSilent
    }
}

/// The loudest sample of a file's audio, read with `AVAssetReader` as 32-bit float PCM. Reading
/// stops at the first sample above `stopAbove`, so a recording with sound is decided within its
/// first buffers; only a silent file is read to the end.
public enum AudioLevelProbe {
    /// The peak in dBFS over every audio track, `-infinity` for digital silence, nil when the file
    /// has no audio track. Throws when the file cannot be read.
    public static func peakDBFS(of url: URL, stopAbove: Double = AudioCheck.silenceFloorDBFS) async throws -> Double? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let stopAmplitude = pow(10, stopAbove / 20)
        var peak: Float = 0
        for track in tracks {
            peak = max(peak, try await peakAmplitude(of: track, in: asset, stopAt: Float(stopAmplitude)))
            if Double(peak) > stopAmplitude { break }
        }
        return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    }

    private static func peakAmplitude(of track: AVAssetTrack, in asset: AVAsset, stopAt: Float) async throws -> Float {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw VideoProbeError.cannotRead("cannot read the audio track") }
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            throw VideoProbeError.cannotRead(String(describing: error))
        }
        var peak: Float = 0
        do {
            while let sample = try await provider.next() {
                peak = max(peak, try sample.withUnsafeSampleBuffer { buffer in try maxAmplitude(in: buffer) })
                if peak > stopAt {
                    reader.cancelReading()
                    break
                }
            }
        } catch {
            throw VideoProbeError.cannotRead(String(describing: error))
        }
        return peak
    }

    private static func maxAmplitude(in sample: CMSampleBuffer) throws -> Float {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return 0 }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        // Copied out, since a block buffer may be split into several memory regions.
        var floats = [Float](repeating: 0, count: count)
        let status = floats.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
        }
        guard status == noErr else { throw VideoProbeError.cannotRead("audio buffer \(status)") }
        var peak: Float = 0
        for value in floats { peak = max(peak, abs(value)) }
        return peak
    }
}
