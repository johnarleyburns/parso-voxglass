import Foundation
import ParsoAudioCore
import VoxglassCore

/// MP3 encoder — a thin shim over `ParsoAudioCore`'s vendored Glint encoder
/// (§16.3). The `Lame.xcframework` binary dependency is gone.
///
/// Glint is the only way Voxglass can produce MP3 on Apple platforms —
/// AudioToolbox decodes MP3 but does not encode it. Voxglass encodes **CBR
/// only**: LibriVox rejects VBR and ACX requires CBR, so there is no VBR path in
/// this product. CBR conformance is proved downstream by walking the MPEG frame
/// headers (§19.3 `TranscoderCBRTests`).
///
/// The encoder takes mono float PCM. Input is always mono in this product (the
/// pipeline downmixes in the decoder).
public struct GlintMP3Encoder: Sendable {

    public init() {}

    /// Encode `samples` (mono, at `sampleRate`) as CBR MP3 at `bitrateKbps`,
    /// prepending `headerData` (the ID3v2 tag) and writing to `outputURL`.
    /// Returns the number of bytes written.
    public func encode(
        samples: [Float],
        sampleRate: Double,
        bitrateKbps: Int,
        headerData: Data?,
        to outputURL: URL
    ) throws -> Int {
        guard !samples.isEmpty else { throw TranscodeError.encoderFailed(status: -1, stderr: "empty input") }

        let buffer = PCMBuffer(
            format: AudioFormat(sampleRate: sampleRate, channelCount: 1),
            capacity: samples.count
        )
        let channel = buffer.channel(0)
        for i in 0..<samples.count { channel[i] = samples[i] }

        let body: Data
        do {
            // `.best` is the closest analogue to the LAME `-q2` this product used.
            body = try AudioFileWriter.encodeMP3(buffer, bitrateKbps: bitrateKbps, quality: .best)
        } catch let error as AudioFileError {
            throw TranscodeError.encoderFailed(status: 0, stderr: "\(error)")
        }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        var total = 0
        if let headerData, !headerData.isEmpty {
            try handle.write(contentsOf: headerData)
            total += headerData.count
        }
        try handle.write(contentsOf: body)
        total += body.count
        return total
    }
}

/// Retained so the historical name keeps resolving; Glint replaced LAME in
/// Phase 4 of the audio-engine unification.
public typealias LameMP3Encoder = GlintMP3Encoder
