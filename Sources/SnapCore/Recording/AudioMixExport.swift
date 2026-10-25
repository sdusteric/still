import AVFoundation
import CoreMedia
import Foundation
import Synchronization

public enum AudioMixExportError: Error, Sendable, Hashable, CustomStringConvertible {
    case noVideoTrack
    case cannotRead(String)
    case cannotWrite(String)

    public var description: String {
        switch self {
        case .noVideoTrack: "the recording has no video track"
        case .cannotRead(let message): "cannot read the recording: \(message)"
        case .cannotWrite(let message): "cannot write the mixed recording: \(message)"
        }
    }
}

/// The post-stop mix of design 20.6 (D64): when a finished recording carries two audio tracks
/// (system audio and microphone), most chat and browser players would play only the first. This
/// writes a copy with the video samples passed through untouched and the audio tracks mixed by an
/// `AVAudioMix` into one AAC track, then swaps it in by rename, so the mp4 path never changes and
/// a failed export leaves the original in place.
public enum AudioMixExport {
    public static let sampleRate = 48_000
    public static let channelCount = 2
    public static let bitRate = 128_000

    /// Mixes the audio tracks of the mp4 at `url` into one when there are two or more.
    /// - Returns: true when the file was rewritten, false when it had at most one audio track.
    @discardableResult
    public static func mixAudioIfNeeded(at url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (tracks, duration) = try await asset.load(.tracks, .duration)
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        guard audioTracks.count >= 2 else { return false }
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw AudioMixExportError.noVideoTrack
        }
        let (formats, transform) = try await videoTrack.load(.formatDescriptions, .preferredTransform)

        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let temporary = folder.appending(path: ".\(base) mixing \(UUID().uuidString.prefix(8)).mp4", directoryHint: .notDirectory)
        do {
            let writer = try await write(
                asset: asset, videoTrack: videoTrack, videoFormat: formats.first, transform: transform,
                audioTracks: audioTracks, duration: duration, to: temporary
            )
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else {
                throw AudioMixExportError.cannotWrite(
                    writer.error.map { String(describing: $0) } ?? "status \(writer.status.rawValue)"
                )
            }
            guard rename(temporary.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
                throw AudioMixExportError.cannotWrite("rename failed: \(String(cString: strerror(errno)))")
            }
        } catch {
            removeLeftover(temporary)
            throw error
        }
        return true
    }

    private static func write(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        videoFormat: CMFormatDescription?,
        transform: CGAffineTransform,
        audioTracks: [AVAssetTrack],
        duration: CMTime,
        to output: URL
    ) async throws -> AVAssetWriter {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioMixExportError.cannotRead(String(describing: error))
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let mixOutput = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        mixOutput.audioMix = mix
        guard reader.canAdd(videoOutput), reader.canAdd(mixOutput) else {
            throw AudioMixExportError.cannotRead("cannot add the track outputs")
        }
        let videoProvider = reader.outputProvider(for: videoOutput)
        let audioProvider = reader.outputProvider(for: mixOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw AudioMixExportError.cannotWrite(String(describing: error))
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.transform = transform
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: bitRate,
            ]
        )
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw AudioMixExportError.cannotWrite("cannot add the writer inputs")
        }
        let videoReceiver = writer.inputReceiver(for: videoInput)
        let audioReceiver = writer.inputReceiver(for: audioInput)

        do {
            try reader.start()
        } catch {
            throw AudioMixExportError.cannotRead(String(describing: error))
        }
        do {
            try writer.start()
        } catch {
            reader.cancelReading()
            throw AudioMixExportError.cannotWrite(String(describing: error))
        }
        writer.startSession(atSourceTime: .zero)

        // A non-real-time writer holds back one input until the other catches up, so the two
        // tracks are copied side by side and each append is retried until its input takes more.
        let abort = CopyAbort()
        do {
            async let video: Void = copy(from: videoProvider, to: videoReceiver, abort: abort)
            async let audio: Void = copy(from: audioProvider, to: audioReceiver, abort: abort)
            _ = try await (video, audio)
        } catch {
            throw failure(writer, reader, error)
        }
        if duration.isNumeric, duration > .zero { writer.endSession(atSourceTime: duration) }
        return writer
    }

    /// Passes every sample of one reader output to one writer input, then finishes the input.
    private static func copy(
        from provider: sending AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>,
        to receiver: sending AVAssetWriterInput.SampleBufferReceiver,
        abort: CopyAbort
    ) async throws {
        do {
            while let sample = try await provider.next() {
                try await append(abort: abort) { try receiver.appendImmediately(sample) }
            }
        } catch {
            abort.set()
            throw error
        }
        receiver.finish()
    }

    /// Retries `attempt` until its input takes the sample. When the other copy has failed it
    /// throws at once: that input belongs to a writer that will not take more, and waiting would
    /// last until the 30 s append timeout.
    package static func append(abort: CopyAbort, _ attempt: () throws -> Bool) async throws {
        do {
            let outcome = try await WriterInputAppend.untilAccepted(giveUp: { abort.isSet }, attempt)
            if outcome == .gaveUp { throw AudioMixExportError.cannotWrite("the other track failed") }
        } catch {
            abort.set()
            throw error
        }
    }

    private static func failure(_ writer: AVAssetWriter, _ reader: AVAssetReader, _ error: any Error) -> AudioMixExportError {
        if let readError = reader.error {
            writer.cancelWriting()
            return .cannotRead(String(describing: readError))
        }
        let message = writer.error.map { String(describing: $0) } ?? String(describing: error)
        writer.cancelWriting()
        reader.cancelReading()
        return .cannotWrite(message)
    }

    private static func removeLeftover(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // A hidden leftover in the item folder goes with the folder at retention.
        }
    }
}

/// Shared by the two copies of one export: the first failure stops the other.
package final class CopyAbort: Sendable {
    private let flag = Atomic<Bool>(false)

    package init() {}

    package var isSet: Bool { flag.load(ordering: .acquiring) }

    package func set() { flag.store(true, ordering: .releasing) }
}
