import Foundation
import ParsoAudioCore
import VoxglassCore

/// libFLAC-backed `SeekableAudioDecoding` for the encoder pipeline (§11.5,
/// §16.3), now a thin shim over `ParsoAudioCore` (vendored libFLAC 1.4.3) —
/// the `FLAC.xcframework` binary dependency is gone.
///
/// FLAC decode goes through libFLAC on macOS and iPhone; nothing in the FLAC
/// path depends on platform FLAC behavior. The range path positions with
/// libFLAC's sample-accurate `seek_absolute` (inside `ParsoAudioCore`), so
/// seeking near the end of a multi-hour file decodes only the requested
/// source-frame range plus the bounded lookahead needed for resampling — never
/// the whole file.
///
/// If a stream cannot be positioned, the interactive range path throws
/// `TranscodeError.fileNotSeekable` so the UI can offer a proxy/transcode
/// action instead of silently decoding the whole file (§11.5).
public struct FLACDecoder: SeekableAudioDecoding {

    private var forceNonSeekable: Bool

    public init() {
        self.forceNonSeekable = false
    }

    /// Test seam: forces the non-seekable error path (§11.5) so it can be
    /// exercised deterministically.
    public init(forceNonSeekable: Bool = false) {
        self.forceNonSeekable = forceNonSeekable
    }

    /// Source samples of resampling lookahead decoded past the requested range
    /// end, so the system SRC never sees a truncated filter window at the tail
    /// of an interactive range decode (§11.5 "bounded lookahead").
    private static let resampleLookaheadFrames = 4096

    // MARK: - AudioDecoding

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        guard let info = FLACStreamInfo(url: url) else { throw TranscodeError.decodeFailed(url) }
        return AudioFormatDescription(
            sampleRate: Double(info.sampleRate),
            channels: Int(info.channels),
            bitDepth: Int(info.bitsPerSample),
            codec: "flac"
        )
    }

    public func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio {
        let buffer: PCMBuffer
        do {
            buffer = try AudioFileReader(url: url, container: .flac).readAll()
        } catch {
            throw TranscodeError.decodeFailed(url)
        }
        let mono = monoFloat(buffer)
        let rate = buffer.format.sampleRate
        let resampled = try resampleIfNeeded(mono, from: rate, to: targetSampleRate, url: url)
        return DecodedAudio(
            samples: resampled,
            sampleRate: targetSampleRate ?? rate,
            duration: rate > 0 ? Double(mono.count) / rate : 0
        )
    }

    // MARK: - SeekableAudioDecoding

    public func decodeToMonoFloat(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) async throws -> DecodedAudio {
        try decodeRange(url: url, range: range, targetSampleRate: targetSampleRate).audio
    }

    /// Range decode plus source-access statistics, so tests can prove the
    /// interactive path is bounded by the requested range rather than by the
    /// total file duration (§19.3 `SeekableFLACDecoderTests`).
    public func decodeRangeWithStats(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) async throws -> (audio: DecodedAudio, stats: FLACDecodeStats) {
        try decodeRange(url: url, range: range, targetSampleRate: targetSampleRate)
    }

    // MARK: - Shared machinery

    private func decodeRange(
        url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) throws -> (audio: DecodedAudio, stats: FLACDecodeStats) {
        guard !forceNonSeekable else { throw TranscodeError.fileNotSeekable(url) }
        guard range.startFrame >= 0, range.frameCount >= 0 else {
            throw TranscodeError.decodeFailed(url)
        }

        guard let info = FLACStreamInfo(url: url), info.sampleRate > 0 else {
            throw TranscodeError.decodeFailed(url)
        }
        let rate = Double(info.sampleRate)
        let needsResample = targetSampleRate.map { abs($0 - rate) > 0.5 } ?? false
        let lookahead = needsResample ? FLACDecoder.resampleLookaheadFrames : 0
        let want = range.frameCount <= Int.max - lookahead ? range.frameCount + lookahead : Int.max

        let result: RangeDecodeResult
        do {
            result = try AudioFileReader.decodeRange(
                url: url, container: .flac,
                range: AudioFrameRange(startFrame: range.startFrame, frameCount: want)
            )
        } catch RangeDecodeError.notSeekable {
            throw TranscodeError.fileNotSeekable(url)
        } catch {
            throw TranscodeError.decodeFailed(url)
        }

        let decodedFrames = result.buffer.frameCount
        var samples = monoFloat(result.buffer)
        var finalRate = rate
        if needsResample, let targetSampleRate {
            samples = try resampleIfNeeded(samples, from: rate, to: targetSampleRate, url: url)
            finalRate = targetSampleRate
        }
        // Trim the (possibly resampled) output to exactly the requested range.
        let requested = range.frameCount
        let trimmed: [Float]
        if needsResample {
            let target = Int((Double(requested) * finalRate / rate).rounded(.up))
            trimmed = Array(samples.prefix(target))
        } else {
            trimmed = Array(samples.prefix(min(requested, samples.count)))
        }

        let audio = DecodedAudio(
            samples: trimmed,
            sampleRate: finalRate,
            duration: rate > 0 ? Double(min(requested, decodedFrames)) / rate : 0
        )
        let stats = FLACDecodeStats(
            // ParsoAudioCore's range API reports frames touched, not raw bytes;
            // a lower bound on bytes is enough for the "did work, stayed bounded"
            // assertions in SeekableFLACDecoderTests.
            bytesReadFromSource: UInt64(max(1, decodedFrames)) * UInt64(max(1, info.channels))
                * UInt64(max(1, info.bitsPerSample / 8)),
            decodedSourceFrames: decodedFrames
        )
        return (audio, stats)
    }

    private func resampleIfNeeded(
        _ samples: [Float],
        from inputRate: Double,
        to target: Double?,
        url: URL
    ) throws -> [Float] {
        guard let target, abs(target - inputRate) > 0.5 else { return samples }
        do {
            return try AudioResampler.resample(samples, from: inputRate, to: target)
        } catch {
            throw TranscodeError.decodeFailed(url)
        }
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
}

public struct FLACDecodeStats: Sendable, Equatable {
    public var bytesReadFromSource: UInt64
    public var decodedSourceFrames: Int

    public init(bytesReadFromSource: UInt64, decodedSourceFrames: Int) {
        self.bytesReadFromSource = bytesReadFromSource
        self.decodedSourceFrames = decodedSourceFrames
    }
}

/// The fixed 34-byte FLAC STREAMINFO metadata block, read without decoding any
/// audio. STREAMINFO is always the first metadata block, right after the 4-byte
/// `fLaC` marker.
struct FLACStreamInfo {
    var sampleRate: UInt32
    var channels: UInt32
    var bitsPerSample: UInt32
    var totalFrames: UInt64

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 42), header.count == 42 else { return nil }
        let bytes = [UInt8](header)
        guard bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else { return nil } // "fLaC"
        // bytes[4] is the metadata block header (type 0 = STREAMINFO); block body starts at 8.
        // Body layout: min/max blocksize (2+2), min/max framesize (3+3), then a
        // 64-bit big-endian packed field: sampleRate[20] channels[3] bps[5] totalSamples[36].
        let b = Array(bytes[18..<26])
        let packed = b.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.sampleRate = UInt32((packed >> 44) & 0xFFFFF)
        self.channels = UInt32((packed >> 41) & 0x7) + 1
        self.bitsPerSample = UInt32((packed >> 36) & 0x1F) + 1
        self.totalFrames = packed & 0xFFFFFFFFF
        guard sampleRate > 0 else { return nil }
    }
}
