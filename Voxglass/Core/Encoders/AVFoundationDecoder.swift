@preconcurrency import AVFoundation
import Foundation
import ParsoAudioCore
import VoxglassCore

/// `SeekableAudioDecoding` for the non-FLAC containers (CAF, WAV, MP3, M4A/AAC,
/// AIFF), now backed by `ParsoAudioCore` (§16.2). Reads to mono float PCM,
/// optionally resampling via `AudioResampler` (libsamplerate).
///
/// MP3 decode stays AudioToolbox-backed inside `ParsoAudioCore`; FLAC files are
/// routed to `FLACDecoder` by `RoutingAudioDecoder`, never through this type.
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
        let buffer: PCMBuffer
        do {
            buffer = try AudioFileReader(url: url).readAll()
        } catch {
            throw TranscodeError.decodeFailed(url)
        }
        return try finish(buffer, targetSampleRate: targetSampleRate, url: url)
    }

    public func decodeToMonoFloat(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) async throws -> DecodedAudio {
        guard range.startFrame >= 0, range.frameCount >= 0 else {
            throw TranscodeError.decodeFailed(url)
        }
        let result: RangeDecodeResult
        do {
            result = try AudioFileReader.decodeRange(
                url: url,
                range: AudioFrameRange(startFrame: range.startFrame, frameCount: range.frameCount)
            )
        } catch RangeDecodeError.notSeekable {
            throw TranscodeError.fileNotSeekable(url)
        } catch {
            throw TranscodeError.decodeFailed(url)
        }
        return try finish(result.buffer, targetSampleRate: targetSampleRate, url: url)
    }

    // MARK: - Conversion

    private func finish(_ buffer: PCMBuffer, targetSampleRate: Double?, url: URL) throws -> DecodedAudio {
        var samples = monoFloat(buffer)
        var rate = buffer.format.sampleRate
        let sourceCount = samples.count
        if let targetSampleRate, abs(targetSampleRate - rate) > 0.5 {
            do {
                samples = try AudioResampler.resample(samples, from: rate, to: targetSampleRate)
            } catch {
                throw TranscodeError.decodeFailed(url)
            }
            rate = targetSampleRate
        }
        return DecodedAudio(
            samples: samples,
            sampleRate: rate,
            duration: buffer.format.sampleRate > 0 ? Double(sourceCount) / buffer.format.sampleRate : 0
        )
    }

    private func monoFloat(_ buffer: PCMBuffer) -> [Float] {
        let frames = buffer.frameCount
        let channels = buffer.channelCount
        guard frames > 0 else { return [] }
        if channels == 1 {
            let ch = buffer.channel(0)
            var out = [Float](repeating: 0, count: frames)
            for i in 0..<frames { out[i] = ch[i] }
            return out
        }
        var out = [Float](repeating: 0, count: frames)
        let inv = Float(1) / Float(channels)
        for c in 0..<channels {
            let ch = buffer.channel(c)
            for i in 0..<frames { out[i] += ch[i] * inv }
        }
        return out
    }

    public enum AVAudioDecoderError: Error {
        case bufferAllocationFailed
        case conversionUnavailable
        case conversionFailed
    }
}
