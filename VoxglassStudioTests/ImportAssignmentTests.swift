import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// Spec §11.5 / §19.4: silence-based segmentation, assignment methods, and the
/// slice-and-commit path of Import Audio, including the mandatory origin
/// declaration and the LibriVox ineligibility warning.
@MainActor
@Suite struct ImportAssignmentTests {

    @MainActor
    private struct Harness {
        let store = InMemoryProductionStore()
        let assets = InMemoryAssetStore()
        let project: AudiobookProject
        let paragraphIDs: [UUID]
        let sourceURL: URL

        init() {
            let ids = SequentialIDGenerator()
            let clock = FixedClock()
            let paragraphs = (0..<6).map { i in
                let text = "Paragraph \(i) text for the import assignment test."
                return Paragraph(id: ids.next(), ordinal: i, text: text, textHash: SHA256Hex.hex(Data(text.utf8)))
            }
            let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter", paragraphs: paragraphs)
            project = AudiobookProject(
                id: ids.next(),
                metadata: BookMetadata(title: "Import Book", author: "A", narrator: "N"),
                chapters: [chapter],
                createdAt: clock.now,
                modifiedAt: clock.now
            )
            paragraphIDs = paragraphs.map(\.id)

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxglass-import-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            sourceURL = root.appendingPathComponent("import.wav")
            writeTwoSegmentWAV(at: sourceURL)
        }

        func model() -> ImportAudioModel {
            ImportAudioModel(project: project, store: store, assets: assets)
        }

        /// 2.0 s tone, 1.0 s silence, 2.0 s tone — the segmenter must produce
        /// two segments.
        private func writeTwoSegmentWAV(at url: URL) {
            let rate = 48_000
            var data = Data(capacity: 44 + rate * 3 * 2)
            func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

            let totalFrames = rate * 5
            let dataSize = totalFrames * 2
            append(Array("RIFF".utf8)); le32(UInt32(36 + dataSize))
            append(Array("WAVE".utf8))
            append(Array("fmt ".utf8)); le32(16); le16(1); le16(1); le32(UInt32(rate)); le32(UInt32(rate * 2)); le16(2); le16(16)
            append(Array("data".utf8)); le32(UInt32(dataSize))

            for i in 0..<totalFrames {
                let t = Double(i) / Double(rate)
                let value: Double
                if t < 2.0 || t >= 3.0 {
                    value = 0.3 * sin(2 * .pi * 440 * t)
                } else {
                    value = 0
                }
                let v = Int16((value * 32767.0).rounded())
                le16(UInt16(bitPattern: v))
            }
            try! data.write(to: url)
        }
    }

    @Test func silenceSplittingProducesTwoSegments() async throws {
        let h = Harness()
        let model = h.model()
        await model.loadFile(at: h.sourceURL)

        #expect(model.segments.count == 2, "expected 2 segments, got \(model.segments.count)")
        #expect(model.sourceFilename == "import.wav")
        #expect(model.error == nil)
        let durations = model.segments.map(\.duration)
        #expect(durations.allSatisfy { $0 > 1.5 })
    }

    @Test func sequentialAssignmentMapsOneToOne() async throws {
        let h = Harness()
        let model = h.model()
        await model.loadFile(at: h.sourceURL)

        let ok = model.assignSequentially(to: Array(h.paragraphIDs.prefix(2)))
        #expect(ok)
        #expect(model.segments[0].paragraphID == h.paragraphIDs[0])
        #expect(model.segments[1].paragraphID == h.paragraphIDs[1])
    }

    @Test func splitAcrossChapterRequiresMatchingCount() async throws {
        let h = Harness()
        let model = h.model()
        await model.loadFile(at: h.sourceURL)

        // 2 segments vs 6 paragraphs: must refuse loudly.
        let ok = model.assignSplitAcrossChapter(to: h.paragraphIDs)
        #expect(!ok)
        #expect(model.error?.contains("adjust the markers") == true)
        #expect(model.segments.allSatisfy { $0.paragraphID == nil })

        let matched = model.assignSplitAcrossChapter(to: Array(h.paragraphIDs.prefix(2)))
        #expect(matched)
        #expect(model.segments[1].paragraphID == h.paragraphIDs[1])
    }

    @Test func originWarningShownForNonHumanOrigins() async throws {
        let h = Harness()
        let model = h.model()
        await model.loadFile(at: h.sourceURL)

        #expect(model.originWarning == nil)
        model.origin = .aiImported
        #expect(model.originWarning == "AI-origin segments make the project ineligible for LibriVox export.")
        model.origin = .unknownImport
        #expect(model.originWarning != nil)
        model.origin = .importedHuman
        #expect(model.originWarning == nil)
    }

    @Test func assignAllSlicesAndPersistsTakesWithRealSHA256() async throws {
        let h = Harness()
        try await h.store.save(h.project)
        let model = h.model()
        await model.loadFile(at: h.sourceURL)
        model.origin = .importedHuman
        #expect(model.assignSequentially(to: Array(h.paragraphIDs.prefix(2))))
        #expect(model.canAssign)

        await model.assignAll()

        #expect(model.importedTakeCount == 2)
        #expect(model.error == nil)

        let reloaded = try await h.store.load()
        let takes = reloaded.allParagraphs.flatMap(\.takes)
        #expect(takes.count == 2)
        for take in takes {
            #expect(take.origin == .importedHuman(sourceFilename: "import.wav"))
            #expect(!take.assetRef.sha256.isEmpty)
            #expect(take.assetRef.byteCount > 0)
            #expect(!take.textHashAtRecording.isEmpty)
            let data = try await h.assets.data(for: take.assetRef)
            #expect(SHA256Hex.hex(data) == take.assetRef.sha256)
        }
        #expect(Set(takes.map(\.paragraphID)) == Set(h.paragraphIDs.prefix(2)))
    }

    @Test func aiImportedTakeGetsProviderLabel() async throws {
        let h = Harness()
        try await h.store.save(h.project)
        let model = h.model()
        await model.loadFile(at: h.sourceURL)
        model.origin = .aiImported
        model.aiProviderLabel = "Test Provider"
        _ = model.assignSequentially(to: Array(h.paragraphIDs.prefix(2)))
        await model.assignAll()

        let reloaded = try await h.store.load()
        let takes = reloaded.allParagraphs.flatMap(\.takes)
        #expect(takes.allSatisfy { $0.origin == .aiImported(providerLabel: "Test Provider") })
    }

    @Test func assignRequiresOriginAndFullAssignment() async throws {
        let h = Harness()
        let model = h.model()
        await model.loadFile(at: h.sourceURL)

        #expect(!model.canAssign)
        await model.assignAll()
        #expect(model.error?.contains("Choose an origin") == true)

        model.origin = .importedHuman
        #expect(!model.canAssign, "partial assignment must still block")
        await model.assignAll()
        #expect(model.error?.contains("assign every segment") == true)
    }
}
