import Foundation
import Testing
import VoxglassCore
import VoxglassEncoders
import VoxglassCoreTestSupport

/// P7 acceptance (spec §1.4, §13): the Internet Archive lane runs end to end
/// through the real encoders — FLAC lossless masters, MP3 derivatives at the
/// profile bitrate, metadata sidecars, checksums, and the submission checklist
/// with the ready-to-paste `ia upload` command. The path is free: gate G-P2
/// greps the builder source for `ProFeature`/`LicenseGate`.
@Suite struct InternetArchiveExportTests {

    @Test func iaReadyExportsFlacMastersDerivativesAndChecklist() async throws {
        let project = DestinationFixtures.iaReady()
        let identifier = "ready_book_author_narrator"
        let exportsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ia-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        let reportedPhases = LockedIAPhases()
        let bundle = try await InternetArchivePackageBuilder().build(
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: VoxTranscoder(),
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(
                includeMP3Derivatives: true,
                generatedAt: Date(timeIntervalSinceReferenceDate: 0)
            ),
            progress: { reportedPhases.append($0.phase) }
        )

        #expect(!reportedPhases.isEmpty)

        // ── Lossless FLAC masters, one per chapter (§3.3).
        let masters = bundle.files.filter { $0.role == .chapter }
        #expect(masters.count == 3)
        #expect(masters.allSatisfy { $0.url.pathExtension == "flac" })

        // ── MP3 derivatives at the profile's 192 kbps CBR, 44.1 kHz mono.
        let derivatives = bundle.files.filter { $0.role == .secondaryAudio }
        #expect(derivatives.count == 3)
        for derivative in derivatives {
            let data = try Data(contentsOf: derivative.url)
            #expect(MP3FrameParser.verifies(data: data, expectedKbps: 192, sampleRateHz: 44_100, mono: true))
        }

        // ── File naming: <identifier>_NN_<slug>.flac / .mp3 (§3.3.4).
        let names = Set(bundle.files.map { $0.url.lastPathComponent })
        #expect(names.contains { $0.hasPrefix("\(identifier)_01_") && $0.hasSuffix(".flac") })
        #expect(names.contains { $0.hasPrefix("\(identifier)_01_") && $0.hasSuffix(".mp3") })

        // ── Checksums list every delivered audio file's content hash.
        let checksums = try String(contentsOf: bundle.checksumURL!, encoding: .utf8)
        for file in masters + derivatives {
            #expect(checksums.contains(file.sha256 + "  " + file.url.lastPathComponent))
        }

        // ── Metadata sidecars (meta.json + meta.xml) and the checklist.
        #expect(names.contains("\(identifier)_meta.json"))
        #expect(names.contains("\(identifier)_meta.xml"))
        #expect(names.contains("submission-checklist.md"))

        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.manifestURL!)) as? [String: Any]
        #expect(manifest?["identifier"] as? String == identifier)
        #expect(manifest?["mediatype"] as? String == "audio")

        let checklist = try String(contentsOf: bundle.checklistURL, encoding: .utf8)
        #expect(checklist.contains("ia upload \(identifier)"))
        #expect(checklist.contains(LegalStrings.noCopyrightDetermination))
    }

    @Test func iaFixturesFileMatchesArchiveNamingConvention() {
        // The archive identifier drives both the directory and the filenames;
        // keep the fixture and the naming rule in lockstep so the e2e above
        // cannot silently break its own expectations.
        let project = DestinationFixtures.iaReady()
        #expect(project.metadata.archiveIdentifier == "ready_book_author_narrator")
    }
}

private final class LockedIAPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExportPhase] = []
    func append(_ value: ExportPhase) { lock.lock(); values.append(value); lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return values.isEmpty }
}
