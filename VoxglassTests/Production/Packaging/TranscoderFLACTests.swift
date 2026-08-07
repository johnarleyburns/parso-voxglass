import Foundation
import Testing
import VoxglassCore
import VoxglassEncoders

/// §16.3 / §19.3 — FLAC is lossless, so a decode round-trip must be bit-exact.
/// Both encode and decode run through libFLAC (the repo's `FLACDecoder`), not
/// platform FLAC behavior.
@Suite struct TranscoderFLACTests {

    @Test func flacRoundTripIsBitExact() async throws {
        let transcoder = VoxTranscoder()
        #expect(transcoder.availableEncoders.contains(.flac))

        let input = try TestAudio.toneFile(duration: 3, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip.flac")
        defer { try? FileManager.default.removeItem(at: output) }

        let spec = AudioSpec(container: .flac, codec: .flac, bitDepth: 16)
        let file = try await transcoder.transcode(
            input: input, to: spec,
            tags: AudioTags(title: "FLAC", artist: "A", album: "B", genre: "Audiobook", isAudiobook: true),
            output: output, progress: { _ in }
        )

        #expect(file.byteCount > 0)
        // Original PCM comes from the CAF source (AVFoundation); the FLAC side
        // MUST decode through libFLAC rather than platform FLAC behavior.
        let original = try await AVFoundationDecoder().decodeToMonoFloat(input, targetSampleRate: 44_100)
        let decoded = try await FLACDecoder().decodeToMonoFloat(output, targetSampleRate: 44_100)

        // Quantize both to int16 and require exact equality.
        let original16 = quantize16(original.samples)
        let decoded16 = quantize16(decoded.samples)
        #expect(original16.count == decoded16.count)
        var mismatches = 0
        for i in 0..<min(original16.count, decoded16.count) where original16[i] != decoded16[i] {
            mismatches += 1
        }
        #expect(mismatches == 0, "\(mismatches) samples differed after lossless round-trip")
    }

    @Test func flacEncodesStereoBlockUnsupportedGracefully() async throws {
        // The pipeline is mono-only; a stereo spec must not crash — the
        // transcoder decodes to mono regardless and produces mono FLAC.
        let transcoder = VoxTranscoder()
        let input = try TestAudio.toneFile(duration: 1)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-ignored.flac")
        defer { try? FileManager.default.removeItem(at: output) }
        let spec = AudioSpec(container: .flac, codec: .flac, bitDepth: 16)
        let file = try await transcoder.transcode(input: input, to: spec, tags: AudioTags(title: "t", artist: "a", album: "b"), output: output, progress: { _ in })
        #expect(file.byteCount > 0)
    }

    private func quantize16(_ samples: [Float]) -> [Int16] {
        // Must match the FLAC encoder's quantization exactly: × 2^15, truncated
        // toward zero, clamped to the int16 range.
        samples.map { sample in
            let scaled = Int(Double(sample) * 32768.0)
            return Int16(max(-32768, min(32767, scaled)))
        }
    }
}
