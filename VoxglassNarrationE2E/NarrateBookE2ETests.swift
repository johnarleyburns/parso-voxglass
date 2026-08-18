import AVFoundation
import XCTest
import VoxglassCore
import VoxglassEncoders
@testable import Voxglass

@MainActor
final class NarrateBookE2ETests: XCTestCase {
    func testNarratesAndExportsAListenableAudiobook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-narration-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = NarrationProjectRepository(
            applicationSupport: root,
            clock: NarrationE2EClock(),
            ids: NarrationE2EIDGenerator()
        )
        let seeded = try await NarrationE2EFixture.seed(into: repository)
        XCTAssertEqual(seeded.chapters.count, 3)
        XCTAssertEqual(seeded.chapters.flatMap(\.paragraphs).count, 18, "Four body paragraphs plus generated intro/outro per chapter")

        let capture = TTSAudioCapture()
        let model = NarrationFlowModel(repository: repository, existing: seeded, capture: capture)
        let library = E2ELibraryImporter(clock: repository.clock.now)
        model.library = library
        await model.load(seeded)

        for paragraph in seeded.allParagraphs {
            await model.startRecordingParagraph(paragraph.id)
            XCTAssertTrue(model.isRecording, "Speech synthesis did not produce a take for paragraph \(paragraph.ordinal)")
            await model.stopRecordingParagraph(paragraph.id)
            model.acceptParagraph(paragraph.id)
        }
        await model.persist()
        XCTAssertTrue(model.readyToAssemble)

        await model.recomputeAllMetrics()
        let analyzed = try await repository.load(seeded.id)
        XCTAssertTrue(analyzed.allParagraphs.allSatisfy { $0.selectedTake?.metrics != nil })

        model.validationDestination = .personalMaster
        model.exportScopeChoice = .wholeBook
        await model.runValidation()
        XCTAssertTrue(model.blockingValidationIssues.isEmpty, model.blockingValidationIssues.map(\.message).joined(separator: "\n"))
        await model.runExport()

        let bundle = try XCTUnwrap(model.exportBundle, model.exportError ?? "No export bundle")
        XCTAssertNil(model.exportError)
        let chapterFiles = bundle.files.filter { $0.pathExtension.lowercased() == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(chapterFiles.count, seeded.chapters.count)

        var measurements: [(String, TimeInterval, Double, Double)] = []
        for (index, url) in chapterFiles.enumerated() {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let expected = analyzed.chapters[index].paragraphs.compactMap(\.selectedTake).reduce(0) { $0 + $1.duration }
            XCTAssertEqual(duration, expected, accuracy: max(0.25, expected * 0.05))
            let metrics = try await AudioMetricsCalculator(decoder: AVFoundationDecoder()).metrics(for: url)
            XCTAssertGreaterThan(metrics.rmsDBFS, -45)
            XCTAssertLessThan(metrics.truePeakDBFS, -0.1)
            measurements.append((url.lastPathComponent, duration, metrics.rmsDBFS, metrics.truePeakDBFS))
        }

        let checksumURL = bundle.directory.appendingPathComponent("checksums.sha256")
        let checksums = try String(contentsOf: checksumURL, encoding: .utf8)
        for url in chapterFiles {
            XCTAssertTrue(checksums.contains(try SHA256Hex.hex(contentsOf: url) + "  " + url.lastPathComponent))
        }

        let imported = try XCTUnwrap(model.importedBook)
        XCTAssertEqual(imported.chapters.count, seeded.chapters.count)
        XCTAssertEqual(imported.chapters.map(\.title), seeded.chapters.map(\.title))
        XCTAssertTrue(imported.chapters.allSatisfy { $0.localURL.map { FileManager.default.fileExists(atPath: $0.path) } == true })
        await library.play(imported)
        XCTAssertEqual(library.playedBookID, imported.id)

        for measurement in measurements {
            print("E2E_AUDIO \(measurement.0) duration=\(String(format: "%.2f", measurement.1))s rms=\(String(format: "%.2f", measurement.2))dBFS peak=\(String(format: "%.2f", measurement.3))dBFS")
        }
        print("E2E_PACKAGE \(bundle.directory.path)")
    }
}

@MainActor
private final class E2ELibraryImporter: NarrationLibraryImporting {
    private let clock: Date
    private(set) var playedBookID: UUID?

    init(clock: Date) { self.clock = clock }

    func importNarration(directory: URL, title: String, files: [LocalAudioImport]) async throws -> BookWithChapters {
        let bookID = UUID(uuidString: "00000000-0000-4000-9000-000000000001")!
        let sourceID = UUID(uuidString: "00000000-0000-4000-9000-000000000002")!
        let book = Book(
            id: bookID,
            title: title,
            authors: ["Aesop"],
            narrators: ["Voxglass Test Reader"],
            sourceID: sourceID,
            createdAt: clock,
            updatedAt: clock
        )
        let chapters = files.enumerated().map { index, file in
            Chapter(
                id: UUID(uuidString: String(format: "00000000-0000-4000-9001-%012x", index + 1))!,
                bookID: bookID,
                title: file.title,
                sortKey: file.sortKey,
                index: index,
                duration: file.duration,
                localURL: file.url,
                narrators: ["Voxglass Test Reader"]
            )
        }
        return BookWithChapters(book: book, chapters: chapters)
    }

    func play(_ book: BookWithChapters) async {
        playedBookID = book.id
    }
}
