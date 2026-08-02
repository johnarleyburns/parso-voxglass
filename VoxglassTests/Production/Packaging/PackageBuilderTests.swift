import Foundation
import Testing
import VoxglassCore
import VoxglassEncoders
import VoxglassCoreTestSupport

/// Builder-level behavior: preconditions, artifact layout, and failure paths
/// (§16.4–16.9). The full LibriVox acceptance lives in `ExportEndToEndTests`.
@Suite struct PackageBuilderTests {

    private func makeExportsRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func internetArchiveBuilderRequiresIdentifier() async throws {
        let project = ProjectFixtures.librivoxReady() // no archiveIdentifier
        let exportsRoot = try makeExportsRoot()
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        do {
            _ = try await InternetArchivePackageBuilder().build(
                project: project,
                renders: ToneChapterRenderer(),
                transcoder: VoxTranscoder(),
                assets: InMemoryAssetStore(),
                into: exportsRoot,
                options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
                progress: { _ in }
            )
            Issue.record("Expected projectNotReady")
        } catch let error as PackagingError {
            guard case .projectNotReady = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let contents = try FileManager.default.contentsOfDirectory(at: exportsRoot, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }

    @Test func internetArchiveBuilderProducesMastersDerivativesAndArtifacts() async throws {
        let project = DestinationFixtures.iaReady()
        let exportsRoot = try makeExportsRoot()
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        let bundle = try await InternetArchivePackageBuilder().build(
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: VoxTranscoder(),
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(
                includeMP3Derivatives: true,
                useTestCollection: true,
                generatedAt: Date(timeIntervalSinceReferenceDate: 0)
            ),
            progress: { _ in }
        )

        let identifier = "ready_book_author_narrator"
        let names = Set(bundle.files.map { $0.url.lastPathComponent })
        #expect(names.contains("\(identifier)_01_chapter_1.flac"))
        #expect(names.contains("\(identifier)_01_chapter_1.mp3"))
        #expect(names.contains("\(identifier)_meta.json"))
        #expect(names.contains("\(identifier)_meta.xml"))
        #expect(names.contains("\(identifier)_files.sha256"))
        #expect(names.contains("submission-checklist.md"))

        let masters = bundle.files.filter { $0.role == .chapter }
        let derivatives = bundle.files.filter { $0.role == .secondaryAudio }
        #expect(masters.count == 3)
        #expect(derivatives.count == 3)

        // Masters must be real FLAC (the FLAC encoder is available).
        for master in masters {
            #expect(master.url.pathExtension == "flac")
            let metrics = try await AudioMetricsCalculator(decoder: AVFoundationDecoder()).metrics(for: master.url)
            #expect(metrics.sampleRate == 44_100)
        }

        // The checklist includes a ready-to-paste ia upload command (§3.3.4).
        let checklist = try String(contentsOf: bundle.checklistURL, encoding: .utf8)
        #expect(checklist.contains("ia upload \(identifier)"))
        #expect(checklist.contains("test_collection"))

        // Validation of the IA package passed clean, so the AI disclosure note
        // is absent (human-only project) — the note appears only with AI audio.
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.manifestURL!)) as? [String: Any]
        #expect(meta?["notes"] as? String == "")
    }

    @Test func retailBuilderBlocksWithoutCreditsAndCover() async throws {
        // librivoxReady has no credits chapters and no cover → blocking issues.
        let project = ProjectFixtures.librivoxReady()
        let exportsRoot = try makeExportsRoot()
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        do {
            _ = try await RetailMasterPackageBuilder().build(
                project: project,
                renders: ToneChapterRenderer(),
                transcoder: VoxTranscoder(),
                assets: InMemoryAssetStore(),
                into: exportsRoot,
                options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
                progress: { _ in }
            )
            Issue.record("Expected blockingIssues")
        } catch let error as PackagingError {
            guard case .blockingIssues(let issues) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(issues.contains { $0.code == .missingOpeningCredits || $0.code == .missingClosingCredits || $0.code == .missingCoverArt })
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func retailBuilderProducesChapterizedPackage() async throws {
        let project = DestinationFixtures.retailReady()
        let exportsRoot = try makeExportsRoot()
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        let firstBodyParagraph = project.chapters
            .first { $0.role == .body }?
            .paragraphs
            .first { $0.selectedTakeID != nil }?.id

        let bundle = try await RetailMasterPackageBuilder().build(
            project: project,
            renders: ToneChapterRenderer(),
            transcoder: VoxTranscoder(),
            assets: InMemoryAssetStore(),
            into: exportsRoot,
            options: ExportOptions(
                applyMastering: true,
                retailSample: RetailSampleSelection(startParagraphID: firstBodyParagraph ?? UUID(), duration: 90),
                generatedAt: Date(timeIntervalSinceReferenceDate: 0)
            ),
            progress: { _ in }
        )

        let names = Set(bundle.files.map { $0.url.lastPathComponent })
        #expect(names.contains("01 - Opening Credits.mp3"))
        #expect(names.contains("02 - Chapter 1.mp3"))
        #expect(names.contains("delivery-metadata.json"))
        #expect(names.contains("checksums.sha256"))
        #expect(names.contains("submission-checklist.md"))
        #expect(bundle.files.contains { $0.url.pathExtension == "m4b" })

        // Chapter MP3s were mastered to the ACX speech-RMS target and
        // re-measured on the delivered bytes.
        let chapterFiles = bundle.files.filter { $0.role == .chapter && $0.url.pathExtension == "mp3" }
        #expect(chapterFiles.count == 4) // opening + 2 body + closing
        for file in chapterFiles {
            let measured = try #require(file.measured)
            #expect(measured.rmsDBFS >= -23 && measured.rmsDBFS <= -18)
            #expect(measured.truePeakDBFS <= -3.0)
        }

        // Retail sample present and starts with narration. The resolved
        // duration is bounded by the recorded audio available in the fixture
        // (the [60, 300] s rule is enforced on the *selection* by validation,
        // which the builder already passed).
        let sample = bundle.files.first { $0.role == .sample }
        #expect(sample != nil)
        #expect(sample?.url.lastPathComponent == "retail-book-retail-sample.mp3")
        let sampleDuration = try #require(sample?.duration)
        #expect(sampleDuration > 0 && sampleDuration <= 300)
    }
}
