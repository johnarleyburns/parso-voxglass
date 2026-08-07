import AVFoundation
import Foundation
import VoxglassCore

/// AVFoundation-backed `AudioDecoding` for the encoder pipeline (§16.2). Reads
/// any AVFoundation-supported file (CAF, WAV, MP3, M4A) into mono float PCM,
/// optionally resampling to a target rate via `AudioResampler`.
///
/// MP3 decode MAY remain AVFoundation-backed (§16.3); FLAC files are routed to
/// `FLACDecoder` (libFLAC) by `RoutingAudioDecoder`, never through this type.
///
/// Also conforms to `SeekableAudioDecoding` so MP3/WAV paragraph preview can
/// use `AVAudioFile.framePosition` instead of reading a whole file.
public struct AVFoundationDecoder: SeekableAudioDecoding {

    public init() {}

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let codec: String
        switch format.settings[AVFormatIDKey] as? UInt32 {
        case kAudioFormatLinearPCM: codec = "pcm"
        case kAudioFormatMPEG4AAC: codec = "aac"
        case kAudioFormatAppleLossless: codec = "alac"
        case kAudioFormatMPEGLayer3: codec = "mp3"
        default: codec = "unknown"
        }
        return AudioFormatDescription(
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount),
            bitDepth: format.settings[AVLinearPCMBitDepthKey] as? Int,
            codec: codec
        )
    }

    public func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AVAudioDecoderError.bufferAllocationFailed
        }
        try file.read(into: buffer)

        var samples = monoFloat(from: buffer)
        var rate = format.sampleRate

        if let targetSampleRate, abs(targetSampleRate - rate) > 0.5 {
            samples = try AudioResampler.resample(samples, from: rate, to: targetSampleRate)
            rate = targetSampleRate
        }

        return DecodedAudio(samples: samples, sampleRate: rate, duration: Double(buffer.frameLength) / format.sampleRate)
    }

    public func decodeToMonoFloat(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) async throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = Int64(file.length)
        let start = max(0, min(range.startFrame, total))
        let count = max(0, min(Int64(range.frameCount), total - start))
        file.framePosition = start

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(count)
        ) else {
            throw AVAudioDecoderError.bufferAllocationFailed
        }
        try file.read(into: buffer)

        var samples = monoFloat(from: buffer)
        var rate = format.sampleRate
        if let targetSampleRate, abs(targetSampleRate - rate) > 0.5 {
            samples = try AudioResampler.resample(samples, from: rate, to: targetSampleRate)
            rate = targetSampleRate
        }
        return DecodedAudio(
            samples: samples,
            sampleRate: rate,
            duration: Double(count) / format.sampleRate
        )
    }

    // MARK: - Conversion

    private func monoFloat(from buffer: AVAudioPCMBuffer) -> [Float] {
        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else {
            return []
        }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frameLength))
        }
        var mono = [Float](repeating: 0, count: frameLength)
        for c in 0..<channels {
            let channel = UnsafeBufferPointer(start: data[c], count: frameLength)
            for i in 0..<frameLength { mono[i] += channel[i] / Float(channels) }
        }
        return mono
    }

    public enum AVAudioDecoderError: Error {
        case bufferAllocationFailed
        case conversionUnavailable
        case conversionFailed
    }
}
