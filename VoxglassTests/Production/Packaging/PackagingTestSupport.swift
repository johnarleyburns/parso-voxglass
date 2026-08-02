import Foundation
import AVFoundation
import VoxglassCore
import VoxglassCoreTestSupport

/// Shared audio generation for the packaging tests: synthetic tone files and a
/// renderer that materializes a `RenderPlan` into real audio (the fixture
/// takes in `ProjectFixtures` do not reference real asset files, so the export
/// tests need a renderer that synthesizes tone per segment instead of decoding
/// the asset store).
enum TestAudio {

    /// Write `duration` seconds of sine tone as a Float32 CAF file.
    static func toneFile(
        duration: TimeInterval,
        sampleRate: Double = 44_100,
        frequency: Double = 440,
        amplitude: Float = 0.25
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-tone-\(UUID().uuidString).caf")
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
        try writeCAF(samples, sampleRate: sampleRate, to: url)
        return url
    }

    static func writeCAF(_ samples: [Float], sampleRate: Double, to url: URL) throws {
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

    /// A real `ChapterRenderable` that synthesizes a quiet 220 Hz tone for each
    /// segment (with the plan's leading/trailing silence and trims) instead of
    /// reading the asset store. Lets the export acceptance run the true
    /// render → master → transcode pipeline without fixture audio on disk.
    static func renderPlan(_ plan: RenderPlan, to url: URL) throws -> ChapterRendering {
        let rate = plan.outputFormat.sampleRate ?? 44_100
        var samples: [Float] = []
        var offsets: [UUID: Range<TimeInterval>] = [:]

        for segment in plan.segments {
            let leading = Int(segment.leadingSilence * rate)
            samples.append(contentsOf: [Float](repeating: 0, count: leading))

            let audioStart = Double(samples.count) / rate
            let duration = segment.trim.upperBound - segment.trim.lowerBound
            let count = Int(duration * rate)
            let gain = pow(10.0, segment.gainDB / 20.0)
            for i in 0..<count {
                let t = Double(i) / rate
                var sample = Float(sin(2 * Double.pi * 220 * t)) * 0.25
                if segment.fadeIn > 0, Double(i) < segment.fadeIn * rate {
                    sample *= Float(Double(i) / (segment.fadeIn * rate))
                }
                if segment.fadeOut > 0, Double(count - i) < segment.fadeOut * rate {
                    sample *= Float(Double(count - i) / (segment.fadeOut * rate))
                }
                samples.append(sample * Float(gain))
            }
            offsets[segment.paragraphID] = audioStart ..< (audioStart + duration)

            let trailing = Int(segment.trailingSilence * rate)
            samples.append(contentsOf: [Float](repeating: 0, count: trailing))
        }

        try writeCAF(samples, sampleRate: rate, to: url)
        let sha = try SHA256Hex.hex(contentsOf: url)
        return ChapterRendering(
            ref: AudioAssetReference(sha256: sha, relativePath: url.lastPathComponent, byteCount: samples.count * 4, contentType: "audio/caf"),
            duration: Double(samples.count) / rate,
            paragraphOffsets: offsets
        )
    }
}

struct ToneChapterRenderer: ChapterRenderable {
    func render(_ plan: RenderPlan, to url: URL, progress: @Sendable (Double) -> Void) async throws -> ChapterRendering {
        try TestAudio.renderPlan(plan, to: url)
    }
}

/// Test fixtures that build on `ProjectFixtures` but satisfy a specific
/// destination's validation preconditions.
enum DestinationFixtures {

    /// The LibriVox-ready fixture plus what Internet Archive requires:
    /// an `archiveIdentifier` and a license URL.
    static func iaReady() -> AudiobookProject {
        var project = ProjectFixtures.librivoxReady()
        project.metadata.archiveIdentifier = "ready_book_author_narrator"
        project.rights.licenseURL = URL(string: "https://creativecommons.org/publicdomain/mark/1.0/")
        return project
    }

    /// A project that passes ACX validation: body chapters recorded, retail
    /// credits chapters (opening + closing) recorded, cover, publisher,
    /// copyright year, and an attested own-copyright basis.
    static func retailReady() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let metadata = BookMetadata(
            title: "Retail Book",
            author: "Retail Author",
            narrator: "Retail Narrator",
            language: "en-US",
            description: "A commercial-ready audiobook.",
            publisher: "Retail Publisher",
            copyrightYear: 2026,
            productionYear: 2026,
            rightsHolder: "Retail Author",
            coverRef: AudioAssetReference(sha256: "coverhash", relativePath: "Artwork/cover.jpg", byteCount: 100, contentType: "image/jpeg")
        )
        let rights = RightsEvidence(
            basis: .ownCopyright,
            editionYear: 2026,
            attestedAt: clock.now,
            attestedBy: "Retail Narrator"
        )

        var chapters: [ProductionChapter] = []
        for i in 0..<2 {
            let chapterID = ids.next()
            var paragraphs: [Paragraph] = []
            for j in 0..<2 {
                paragraphs.append(recordedParagraph(
                    "Paragraph \(j + 1) of chapter \(i + 1) for the retail test.",
                    ordinal: j,
                    ids: ids,
                    clock: clock
                ))
            }
            chapters.append(ProductionChapter(id: chapterID, ordinal: i, title: "Chapter \(i + 1)", role: .body, paragraphs: paragraphs))
        }

        var project = AudiobookProject(
            id: ids.next(),
            metadata: metadata,
            rights: rights,
            chapters: chapters,
            createdAt: clock.now,
            modifiedAt: clock.now
        )

        // Credits via the retail script generator, then recorded.
        let plan = RetailScriptGenerator().plan(for: project)
        var applyClock = FixedClock()
        _ = ScriptApplier().apply(plan, to: &project, ids: ids, clock: applyClock)
        for chapterIndex in project.chapters.indices {
            for paragraphIndex in project.chapters[chapterIndex].paragraphs.indices {
                let paragraph = project.chapters[chapterIndex].paragraphs[paragraphIndex]
                if paragraph.selectedTakeID == nil {
                    project.chapters[chapterIndex].paragraphs[paragraphIndex] = recordedParagraph(
                        paragraph.text, ordinal: paragraph.ordinal, role: paragraph.role, ids: ids, clock: clock
                    )
                }
            }
        }
        return project
    }

    private static func recordedParagraph(
        _ text: String,
        ordinal: Int,
        role: ParagraphRole = .body,
        ids: SequentialIDGenerator,
        clock: FixedClock
    ) -> Paragraph {
        let pID = ids.next()
        let takeID = ids.next()
        let hash = SHA256Hex.hex(Data(text.utf8))
        let metrics = AudioQualityMetrics(
            peakDBFS: -3, truePeakDBFS: -3.5, rmsDBFS: -20, noiseFloorDBFS: -65,
            noiseFloorReliable: true, replayGainDB: 0, clipCount: 0, dcOffset: 0,
            leadingSilence: 0.1, trailingSilence: 0.2, duration: 2,
            sampleRate: 44_100, channels: 1, computedAt: clock.now,
            analyzerVersion: AudioMetricsCalculator.analyzerVersion
        )
        let take = Take(
            id: takeID, paragraphID: pID,
            assetRef: AudioAssetReference(sha256: SHA256Hex.hex(Data("\(text)-t".utf8)), relativePath: "Audio/Original/xx/yy.wav", byteCount: 100_000, contentType: "public.wav"),
            origin: .recorded, recordedAt: clock.now, duration: 2,
            format: AudioFormatDescription(sampleRate: 44_100, channels: 1, bitDepth: 24, codec: "pcm"),
            metrics: metrics, textHashAtRecording: hash
        )
        return Paragraph(id: pID, ordinal: ordinal, text: text, textHash: hash, role: role, takes: [take], selectedTakeID: takeID)
    }
}
