import Foundation
import Testing
import VoxglassCore
import VoxglassEncoders

/// §16.3 / §19.3 — a Voxglass MP3 must be *true* CBR: every MPEG frame carries
/// the same bitrate index. This is the acceptance test for the LAME CBR path:
/// encode 10 s of tone, walk the frame headers, and prove mono 44.1 kHz 128
/// kbps CBR.
@Suite struct TranscoderCBRTests {

    @Test func encodes128CBRMono44100() async throws {
        let transcoder = VoxTranscoder()
        #expect(transcoder.availableEncoders.contains(.mp3))

        let input = try TestAudio.toneFile(duration: 10)
        defer { try? FileManager.default.removeItem(at: input) }

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cbr-test.mp3")
        defer { try? FileManager.default.removeItem(at: output) }

        let spec = AudioSpec(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1, bitrateKbps: 128, isCBR: true)
        let file = try await transcoder.transcode(
            input: input, to: spec,
            tags: AudioTags(title: "CBR", artist: "A", album: "B", genre: "Speech"),
            output: output, progress: { _ in }
        )

        let data = try Data(contentsOf: output)
        let summary = MP3FrameParser.parse(data)
        #expect(summary.frames.count > 50, "expected a long frame stream, got \(summary.frames.count)")
        #expect(summary.isCBR)
        #expect(summary.frames.allSatisfy { $0.bitrateKbps == 128 })
        #expect(summary.frames.allSatisfy { $0.sampleRateHz == 44_100 })
        #expect(summary.frames.allSatisfy { $0.isMono })

        #expect(file.byteCount > 0)
        #expect(file.byteCount < 170_000, "10 s at 128 kbps ≈ 160 KB")
    }

    @Test func decodesBackToMono44100() async throws {
        let transcoder = VoxTranscoder()
        let input = try TestAudio.toneFile(duration: 3)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cbr-decode.mp3")
        defer { try? FileManager.default.removeItem(at: output) }

        let spec = AudioSpec(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1, bitrateKbps: 128, isCBR: true)
        _ = try await transcoder.transcode(input: input, to: spec, tags: AudioTags(title: "t", artist: "a", album: "b"), output: output, progress: { _ in })

        let decoded = try await AVFoundationDecoder().decodeToMonoFloat(output, targetSampleRate: 44_100)
        #expect(abs(decoded.sampleRate - 44_100) < 0.5)
        #expect(decoded.samples.count > 44_100 * 2, "3 s of tone should decode to ~130k samples")
        // Re-measured metrics on the delivered file must be sane.
        let metrics = try await AudioMetricsCalculator(decoder: AVFoundationDecoder()).metrics(for: output)
        #expect(metrics.sampleRate == 44_100)
        #expect(metrics.channels == 1)
    }

    @Test func cbrVerificationHelper() async throws {
        // The frame parser's conformance helper is the single assertion the
        // LibriVox contract rides on; give it a direct check with a golden tone.
        let input = try TestAudio.toneFile(duration: 2)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("verify.mp3")
        defer { try? FileManager.default.removeItem(at: output) }
        let spec = AudioSpec(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1, bitrateKbps: 128, isCBR: true)
        let transcoder = VoxTranscoder()
        _ = try await transcoder.transcode(input: input, to: spec, tags: AudioTags(title: "t", artist: "a", album: "b"), output: output, progress: { _ in })
        let data = try Data(contentsOf: output)
        #expect(MP3FrameParser.verifies(data: data, expectedKbps: 128, sampleRateHz: 44_100, mono: true))
    }
}
