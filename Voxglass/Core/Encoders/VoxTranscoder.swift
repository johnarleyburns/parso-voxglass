import AVFoundation
import Foundation
import VoxglassCore

/// The composition point of the encoder pipeline (§16.3): AVFoundation for
/// Apple-native decode (MP3, WAV, M4A/AAC) and for AAC/ALAC/PCM encode, LAME
/// for MP3, libFLAC for FLAC decode *and* encode. FLAC decode always goes
/// through `FLACDecoder` (libFLAC) on macOS and iPhone, never through platform
/// FLAC behavior (§11.5).
///
/// `availableEncoders` reports what this build can actually encode. LAME and
/// libFLAC are statically linked, so they are present by default, but the
/// flags can be turned off (tests exercise the "encoder unavailable" path) and
/// the composition keeps AAC/ALAC/PCM (AVFoundation) separate from the
/// third-party codecs so a platform without them still degrades gracefully.
public struct VoxTranscoder: AudioTranscoding {

    public var mp3Available: Bool
    public var flacAvailable: Bool
    public var decoder: any AudioDecoding

    public init(
        mp3Available: Bool = true,
        flacAvailable: Bool = true,
        decoder: any AudioDecoding = RoutingAudioDecoder()
    ) {
        self.mp3Available = mp3Available
        self.flacAvailable = flacAvailable
        self.decoder = decoder
    }

    public var availableEncoders: Set<Codec> {
        var set: Set<Codec> = [.pcm, .aacLC, .alac] // AVFoundation always available on macOS.
        if mp3Available { set.insert(.mp3) }
        if flacAvailable { set.insert(.flac) }
        return set
    }

    // MARK: - AudioTranscoding

    public func transcode(
        input: URL,
        to spec: AudioSpec,
        tags: AudioTags,
        output: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ExportedFile {
        guard availableEncoders.contains(spec.codec) else {
            throw TranscodeError.encoderUnavailable(spec.codec.rawValue)
        }

        let decoded = try await decoder.decodeToMonoFloat(input, targetSampleRate: spec.sampleRate)
        progress(0.5)

        switch spec.codec {
        case .mp3:
            guard mp3Available else { throw TranscodeError.encoderUnavailable("mp3") }
            let tagData = try ID3Writer.tagData(for: id3Tag(tags))
            let bytes = try LameMP3Encoder().encode(
                samples: decoded.samples,
                sampleRate: spec.sampleRate ?? decoded.sampleRate,
                bitrateKbps: spec.bitrateKbps ?? 128,
                headerData: tagData,
                to: output
            )
            return try await measuredFile(at: output, duration: decoded.duration, bytes: bytes)
        case .flac:
            guard flacAvailable else { throw TranscodeError.encoderUnavailable("flac") }
            let bytes = try FLACEncoder().encode(
                samples: decoded.samples,
                sampleRate: spec.sampleRate ?? decoded.sampleRate,
                channels: 1,
                bitDepth: spec.bitDepth ?? 16,
                tags: tags,
                to: output
            )
            return try await measuredFile(at: output, duration: decoded.duration, bytes: bytes)
        case .pcm:
            try writePCM(decoded.samples, sampleRate: spec.sampleRate ?? decoded.sampleRate, bitDepth: spec.bitDepth ?? 16, to: output)
            return try await measuredFile(at: output, duration: decoded.duration)
        case .aacLC, .alac:
            try writeCompressed(decoded.samples, sampleRate: spec.sampleRate ?? decoded.sampleRate, bitrateKbps: spec.bitrateKbps ?? 128, alac: spec.codec == .alac, tags: tags, to: output)
            return try await measuredFile(at: output, duration: decoded.duration)
        }
    }

    public func concatenate(
        _ inputs: [URL],
        to spec: AudioSpec,
        chapters: [ChapterMark]?,
        tags: AudioTags,
        output: URL
    ) async throws -> ExportedFile {
        guard spec.codec == .aacLC else {
            throw TranscodeError.unsupportedSpec(spec)
        }
        guard !inputs.isEmpty else {
            throw TranscodeError.decodeFailed(URL(fileURLWithPath: ""))
        }
        var all: [Float] = []
        for input in inputs {
            let decoded = try await decoder.decodeToMonoFloat(input, targetSampleRate: spec.sampleRate)
            all.append(contentsOf: decoded.samples)
        }
        return try MPEG4Writer().writeM4B(
            samples: all,
            sampleRate: spec.sampleRate ?? 44_100,
            bitrateKbps: spec.bitrateKbps ?? 128,
            channels: 1,
            chapters: chapters,
            tags: tags,
            outputURL: output
        )
    }

    public func master(input: URL, target: MasteringTarget, output: URL) async throws -> ExportedFile {
        let decoded = try await decoder.decodeToMonoFloat(input, targetSampleRate: nil)
        let result = MasteringChain.master(samples: decoded.samples, sampleRate: decoded.sampleRate, target: target)
        try writeFloatCAF(result.samples, sampleRate: result.sampleRate, to: output)
        return try await measuredFile(at: output, duration: decoded.duration)
    }

    // MARK: - Writers

    private func writePCM(_ samples: [Float], sampleRate: Double, bitDepth: Int, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let dithered = MasteringChain.tpdfDither(samples, bitDepth: bitDepth)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: bitDepth == 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(dithered.count))!
        buffer.frameLength = AVAudioFrameCount(dithered.count)
        if let channel = buffer.floatChannelData?[0] {
            dithered.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: dithered.count) }
        }
        try file.write(from: buffer)
    }

    private func writeCompressed(_ samples: [Float], sampleRate: Double, bitrateKbps: Int, alac: Bool, tags: AudioTags, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: alac ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrateKbps * 1000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
    }

    private func writeFloatCAF(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
    }

    // MARK: - Output accounting

    private func measuredFile(at url: URL, duration: TimeInterval, bytes: Int? = nil) async throws -> ExportedFile {
        let size = bytes ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let sha = try SHA256Hex.hex(contentsOf: url)
        // Re-measure the *delivered* file at its own rate so builders can assert
        // ACX-style compliance on the exact bytes that ship (§16.13).
        let metrics = try? await AudioMetricsCalculator(decoder: decoder).metrics(for: url)
        return ExportedFile(
            url: url,
            role: .chapter,
            duration: duration,
            byteCount: Int64(size),
            sha256: sha,
            measured: metrics
        )
    }

    private func id3Tag(_ tags: AudioTags) -> ID3Writer.TagData {
        ID3Writer.TagData(
            title: tags.title,
            artist: tags.artist,
            album: tags.album,
            albumArtist: tags.albumArtist,
            composer: tags.composer,
            track: tags.track,
            year: tags.year,
            genre: tags.genre,
            comment: tags.comment,
            copyright: tags.copyright,
            language: tags.language,
            artworkJPEG: tags.artworkJPEG
        )
    }
}
