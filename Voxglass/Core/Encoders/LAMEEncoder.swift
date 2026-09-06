import CLAMEBridge
import Foundation
import ParsoAudioCore
import VoxglassCore

/// This app's `MP3Encoding` conformance (parso-audio-engine's
/// `docs/BYO-CODEC.md` seam), backed by a real vendored LAME 3.100
/// (`Sources/CLAMEBridge`, LGPL-2.1 — see that target's own
/// `vendor/lame-3.100/COPYING`). parso-audio-engine's `ParsoAudioCore` never
/// imports or links LAME; this type is the only place in the dependency
/// graph that does, and it lives entirely in this app's own package.
///
/// This app previously used LAME (via a binary `Lame.xcframework`) and moved
/// to PAE's own Glint encoder in the audio-engine-unification's Phase 4 —
/// see the `phase4-mp3-glint-vs-lame-gate` project note. This restores LAME
/// as the active encoder, this time as source vendored in this app's own
/// tree and driven through PAE's declared seam rather than by overriding
/// PAE's audio handling.
public struct LAMEEncoder: MP3Encoding {
    public init() {}

    public func encode(_ buffer: PCMBuffer, bitrateKbps: Int) throws -> Data {
        let frameCount = buffer.frameCount
        let channelCount = buffer.channelCount
        guard frameCount > 0, channelCount == 1 || channelCount == 2 else {
            throw AudioFileError.writeFailed("LAME encode: unsupported channel count \(channelCount)")
        }

        var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
        for c in 0..<channelCount {
            let src = buffer.channel(c)
            for f in 0..<frameCount {
                interleaved[f * channelCount + c] = src[f]
            }
        }

        var outSize: Int32 = 0
        let encoded: UnsafeMutablePointer<UInt8>? = interleaved.withUnsafeBufferPointer { samples in
            app_lame_encode(samples.baseAddress,
                             Int32(frameCount),
                             Int32(channelCount),
                             Int32(buffer.format.sampleRate.rounded()),
                             Int32(bitrateKbps),
                             &outSize)
        }
        guard let encoded, outSize > 0 else {
            throw AudioFileError.writeFailed("LAME encode failed (bitrate \(bitrateKbps) kbps, \(channelCount)ch @ \(buffer.format.sampleRate) Hz)")
        }
        defer { app_lame_free(encoded) }
        return Data(bytes: encoded, count: Int(outSize))
    }
}

/// The app-facing wrapper `VoxTranscoder` calls: mono float PCM in, an ID3v2
/// header it did not write prepended, one file out. Internally goes through
/// PAE's `MP3Encoding` seam with `LAMEEncoder` above — PAE's own
/// `AudioFileWriter` never sees this app's LAME conformance directly; this
/// wrapper calls the protocol method itself so it can prepend the ID3
/// header the same way the pre-Phase-4 LAME path did.
public struct LameMP3Encoder: Sendable {
    public init() {}

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
            body = try LAMEEncoder().encode(buffer, bitrateKbps: bitrateKbps)
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
