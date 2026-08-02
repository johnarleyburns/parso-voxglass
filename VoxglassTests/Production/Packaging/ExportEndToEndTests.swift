import Foundation
import Testing
import VoxglassCore
import VoxglassEncoders
import VoxglassCoreTestSupport

/// §20 S8 acceptance — "A `librivoxReady()` fixture produces MP3s that decode
/// to 44.1 kHz mono, verify as CBR 128 by frame-header inspection, carry
/// correct ID3 tags and filenames, and pass a re-validation of the *output*."
@Suite struct ExportEndToEndTests {

    @Test func librivoxReadyExportsAValidPackage() async throws {
        let project = ProjectFixtures.librivoxReady()
        let exportsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        var reportedPhases: [ExportPhase] = []
        let transcoder = VoxTranscoder()
        let bundle = try await LibriVoxPackageBuilder().build(
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: transcoder,
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
            progress: { reportedPhases.append($0.phase) }
        )

        #expect(!reportedPhases.isEmpty, "progress must be reported throughout the export")
        #expect(bundle.files.contains { $0.role == .chapter })

        // ── Filenames (§3.2.4): <shorttitle>_NN_<authorlast>.mp3.
        let chapters = bundle.files.filter { $0.role == .chapter }.sorted { ($0.url.lastPathComponent) < ($1.url.lastPathComponent) }
        #expect(chapters.count == 3)
        let sanitizer = FilenameSanitizer()
        for (index, file) in chapters.enumerated() {
            let expected = sanitizer.librivoxFilename(
                shortTitle: "Ready Book", section: index + 1, sectionCount: 3, authorLastName: "Author"
            ) + ".mp3"
            #expect(file.url.lastPathComponent == expected)
        }

        // ── Frame-header inspection (§16.3): every frame is 128 kbps CBR,
        //    44.1 kHz, mono.
        for file in chapters {
            let data = try Data(contentsOf: file.url)
            #expect(MP3FrameParser.verifies(data: data, expectedKbps: 128, sampleRateHz: 44_100, mono: true))
        }

        // ── ID3 tags (§16.6): LibriVox convention per §3.2.5.
        let parsedFirst = try ID3Reader.read(from: chapters[0].url)
        let first = try #require(parsedFirst)
        #expect(first.title == "1 - Chapter 1")
        #expect(first.artist == "Ready Author")
        #expect(first.album == "Ready Book")
        #expect(first.genre == "Speech")
        #expect(first.track?.0 == 1 && first.track?.1 == 3)

        // ── Re-validation of the *output*: decode the delivered MP3 and assert
        //    it satisfies the LibriVox audio contract (no clipping, 44.1 kHz
        //    mono, level within the clipping guard).
        let decoder = AVFoundationDecoder()
        for file in chapters {
            let metrics = try await AudioMetricsCalculator(decoder: decoder).metrics(for: file.url)
            #expect(metrics.sampleRate == 44_100)
            #expect(metrics.channels == 1)
            #expect(metrics.clipCount == 0)
            #expect(metrics.peakDBFS <= -0.3)
        }

        // ── Package artifacts (§16.4): durations, checklist, metadata, checksums.
        let names = Set(bundle.files.map { $0.url.lastPathComponent })
        #expect(names.contains("section-durations.txt"))
        #expect(names.contains("librivox-checklist.md"))
        #expect(names.contains("metadata.json"))
        #expect(names.contains("checksums.sha256"))

        let durations = try String(contentsOf: bundle.rootURL.appendingPathComponent("section-durations.txt"), encoding: .utf8)
        #expect(durations.contains("TOTAL"))

        let checklist = try String(contentsOf: bundle.checklistURL, encoding: .utf8)
        #expect(checklist.contains("Voxglass never uploads on your behalf"))
        #expect(checklist.contains(LegalStrings.noCopyrightDetermination))

        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.manifestURL!)) as? [String: Any]
        #expect(metadata?["destination"] as? String == "librivox")
        let audio = metadata?["audio"] as? [String: Any]
        #expect(audio?["cbr"] as? Bool == true)
        #expect(audio?["bitrateKbps"] as? Int == 128)

        let checksums = try String(contentsOf: bundle.rootURL.appendingPathComponent("checksums.sha256"), encoding: .utf8)
        for file in chapters {
            #expect(checksums.contains(file.sha256 + "  " + file.url.lastPathComponent))
        }
    }

    @Test func singleChapterScopeExportsOneFile() async throws {
        // LibriVox's real workflow posts sections one at a time (§16.11).
        let project = ProjectFixtures.librivoxReady()
        let chapterID = project.chapters[1].id
        let exportsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        let bundle = try await LibriVoxPackageBuilder().build(
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: VoxTranscoder(),
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(
                scope: .chapters([chapterID]),
                generatedAt: Date(timeIntervalSinceReferenceDate: 0)
            ),
            progress: { _ in }
        )
        let chapters = bundle.files.filter { $0.role == .chapter }
        #expect(chapters.count == 1)
        #expect(chapters[0].chapterID == chapterID)
    }
}
