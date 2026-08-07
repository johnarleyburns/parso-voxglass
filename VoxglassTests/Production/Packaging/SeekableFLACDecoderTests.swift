import Foundation
import Testing
import VoxglassCore
import VoxglassEncoders

/// §11.5 / §19.3 `SeekableFLACDecoderTests` — the interactive range path of a
/// long FLAC file must be bounded by the requested range, not by total file
/// duration, and must return PCM that matches the same slice of a full decode.
///
/// The fixtures are synthesized directly with `FLACEncoder` (no AVFoundation
/// FLAC anywhere), so every decode in these tests goes through libFLAC. The
/// suite is serialized because each fixture is a few megabytes of synthesized
/// PCM and running five at once is needlessly heavy.
@Suite(.serialized) struct SeekableFLACDecoderTests {

    /// A long mono 16-bit fixture. 3 minutes is enough to make a
    /// decode-from-the-beginning fallback unambiguously worse than the seek
    /// path (millions of frames vs a few thousand) while staying cheap enough
    /// for a logic suite.
    private let fixtureSeconds: TimeInterval = 180
    private let sampleRate = 44_100.0

    @Test func rangeDecodeNearEndMatchesFullDecode() async throws {
        let flac = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: flac) }

        let decoder = FLACDecoder()
        let full = try await decoder.decodeToMonoFloat(flac, targetSampleRate: nil)

        let total = full.samples.count
        let start = Int64(total - Int(5 * sampleRate))
        let requested = Int(3 * sampleRate)
        let range = try await decoder.decodeToMonoFloat(
            flac, range: AudioDecodeRange(startFrame: start, frameCount: requested), targetSampleRate: nil
        )

        #expect(range.sampleRate == sampleRate)
        #expect(range.samples.count == requested)
        let expected = Array(full.samples[Int(start)..<(Int(start) + requested)])
        #expect(range.samples == expected, "range slice diverged from full decode")
    }

    @Test func rangeDecodeAccessIsBoundedByRequestedRange() async throws {
        let flac = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: flac) }

        let decoder = FLACDecoder()
        let totalFrames = Int(fixtureSeconds * sampleRate)

        let start = Int64(totalFrames - Int(8 * sampleRate))
        let requested = Int(4 * sampleRate)
        let result = try await decoder.decodeRangeWithStats(
            flac, range: AudioDecodeRange(startFrame: start, frameCount: requested), targetSampleRate: nil
        )

        // The decoder must not have decoded the whole file just to reach the
        // tail: source frames read should be ~requested — a tiny fraction of
        // the 7.9M-frame fixture — proving access is bounded by the range.
        #expect(result.stats.decodedSourceFrames >= requested)
        #expect(result.stats.decodedSourceFrames < requested * 2)
        #expect(result.stats.decodedSourceFrames < totalFrames / 4)
        #expect(result.stats.bytesReadFromSource > 0)
        #expect(result.audio.samples.count == requested)
    }

    @Test func rangeDecodeResamplesToTargetRate() async throws {
        let flac = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: flac) }

        let decoder = FLACDecoder()
        let totalFrames = Int(fixtureSeconds * sampleRate)
        let start = Int64(totalFrames - Int(4 * sampleRate))
        let requested = Int(2 * sampleRate)

        let downsampled = try await decoder.decodeToMonoFloat(
            flac,
            range: AudioDecodeRange(startFrame: start, frameCount: requested),
            targetSampleRate: sampleRate / 2
        )

        #expect(downsampled.sampleRate == sampleRate / 2)
        #expect(abs(downsampled.samples.count - requested / 2) <= 1)
    }

    @Test func describeReportsStreamInfoWithoutFrameDecode() async throws {
        let flac = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: flac) }

        // Regression: the sample rate/channel/bit-depth getters on libFLAC's
        // stream decoder are populated from *frame headers*, not STREAMINFO.
        // Reading them right after metadata processing used to yield 0s.
        let desc = try await FLACDecoder().describe(flac)
        #expect(desc.sampleRate == sampleRate)
        #expect(desc.channels == 1)
        #expect(desc.bitDepth == 16)
        #expect(desc.codec == "flac")
    }

    @Test func nonSeekableStreamThrowsFileNotSeekable() async throws {
        let flac = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: flac) }

        let decoder = FLACDecoder(forceNonSeekable: true)
        await #expect(throws: TranscodeError.fileNotSeekable(flac)) {
            try await decoder.decodeToMonoFloat(
                flac,
                range: AudioDecodeRange(startFrame: 0, frameCount: 44_100),
                targetSampleRate: nil
            )
        }
    }

    // MARK: - Fixture

    private func makeFixture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seekable-fixture-\(UUID().uuidString).flac")
        let count = Int(fixtureSeconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = 0.25 * Float(sin(2 * Double.pi * 220 * Double(i) / sampleRate))
        }
        _ = try FLACEncoder().encode(
            samples: samples,
            sampleRate: sampleRate,
            channels: 1,
            bitDepth: 16,
            tags: AudioTags(title: "Fixture", artist: "Test", album: "Seek"),
            to: url
        )
        return url
    }
}
