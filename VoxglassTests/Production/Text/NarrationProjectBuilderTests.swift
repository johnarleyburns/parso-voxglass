import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// P5 acceptance (spec §17): a 12-chapter TXT import reaches a dashboard with
/// correct per-chapter counts.
@Suite struct NarrationProjectBuilderTests {

    /// Builds the body text of a 12-chapter TXT where chapter *i* has exactly
    /// `i` body paragraphs, so per-chapter counts are uniquely identifiable.
    private func twelveChapterTXT() -> String {
        var lines: [String] = []
        for chapter in 1...12 {
            lines.append("CHAPTER \(chapter)")
            lines.append("")
            for paragraph in 1...chapter {
                lines.append("Chapter \(chapter), paragraph \(paragraph). This is public domain prose used only to prove chapter counts survive import.")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test func twelveChapterTXTReachesDashboardWithCorrectPerChapterCounts() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("p5_twelve_chapter_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try twelveChapterTXT().write(to: tmp, atomically: true, encoding: .utf8)

        let document = try await TXTImporter().extract(from: tmp)
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let build = NarrationProjectBuilder().build(
            document: document,
            title: "Twelve Chapters",
            author: "A Public Domain Author",
            narrator: "Narrator",
            sourceURL: URL(string: "https://example.com/book"),
            ids: ids,
            clock: clock
        )

        let project = build.project
        #expect(project.chapters.count == 12)

        let dashboard = ProjectDashboard(project: project)
        #expect(dashboard.chapterCount == 12)
        #expect(dashboard.chapters.count == 12)

        // Every body chapter: heading paragraph + `i` body paragraphs + the
        // generated LibriVox intro and outro (mockup 03: "generated LibriVox
        // disclaimer added"). Chapter 1 has 1 body paragraph → 4 total.
        for (index, progress) in dashboard.chapters.enumerated() {
            let chapterNumber = index + 1
            #expect(progress.title.hasPrefix("CHAPTER \(chapterNumber)") || progress.title.contains("Chapter"))
            #expect(progress.paragraphCount == 1 + chapterNumber + 2, "chapter \(chapterNumber) count wrong")
            #expect(progress.recordedCount == 0)
            #expect(progress.approvedCount == 0)
            #expect(progress.isNotStarted)
            #expect(!progress.isComplete)
        }

        // Record next resolves to the first paragraph in document order: the
        // opening LibriVox intro of chapter 1.
        #expect(dashboard.recordNextParagraphID != nil)
        #expect(dashboard.recordNext?.chapterOrdinal == 0)
        #expect(dashboard.recordNext?.paragraphNumber == 1)

        // Counts agree with the source: 1+2+…+12 = 78 body paragraphs plus the
        // heading (12) plus intro/outro (24) = 114 paragraphs.
        #expect(dashboard.paragraphCount == 114)
        #expect(dashboard.recordedCount == 0)
        #expect(dashboard.chaptersComplete == 0)
    }

    @Test func recordNextFallsBackToNeedsPickupWhenEverythingRecorded() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        var project = ProjectFixtures.tiny()

        // Record + approve every paragraph except one needsPickup.
        for chapterIndex in project.chapters.indices {
            for paragraphIndex in project.chapters[chapterIndex].paragraphs.indices {
                let pid = project.chapters[chapterIndex].paragraphs[paragraphIndex].id
                let takeID = ids.next()
                let take = Take(
                    id: takeID,
                    paragraphID: pid,
                    assetRef: AudioAssetReference(sha256: "sha", relativePath: "path", byteCount: 1, contentType: "audio/wav"),
                    origin: .recorded,
                    recordedAt: clock.now,
                    duration: 1,
                    format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
                    textHashAtRecording: project.chapters[chapterIndex].paragraphs[paragraphIndex].textHash
                )
                project.chapters[chapterIndex].paragraphs[paragraphIndex].takes = [take]
                project.chapters[chapterIndex].paragraphs[paragraphIndex].selectedTakeID = takeID
                project.chapters[chapterIndex].paragraphs[paragraphIndex].reviewState = .approved
            }
        }

        // Mark the last paragraph needsPickup; record-next must resolve to it.
        let lastChapter = project.chapters.count - 1
        let lastParagraph = project.chapters[lastChapter].paragraphs.count - 1
        project.chapters[lastChapter].paragraphs[lastParagraph].reviewState = .needsPickup

        let dashboard = ProjectDashboard(project: project)
        #expect(dashboard.recordNextParagraphID == project.chapters[lastChapter].paragraphs[lastParagraph].id)
    }

    @Test func driftIsCountedFromSelectedTakeTextHash() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let text = "The original paragraph text to record against."
        let hash = TextNormalizer.hash(text)
        let pid = ids.next()
        let takeID = ids.next()
        let take = Take(
            id: takeID,
            paragraphID: pid,
            assetRef: AudioAssetReference(sha256: "sha", relativePath: "path", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded,
            recordedAt: clock.now,
            duration: 1,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
            textHashAtRecording: hash
        )
        // Paragraph text edited after recording → textHash differs.
        let paragraph = Paragraph(
            id: pid,
            ordinal: 0,
            text: "The paragraph text was changed after recording.",
            textHash: TextNormalizer.hash("The paragraph text was changed after recording."),
            takes: [take],
            selectedTakeID: takeID
        )
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Drift", author: "A", narrator: "N"),
            chapters: [ProductionChapter(id: ids.next(), ordinal: 0, title: "Ch1", paragraphs: [paragraph])],
            createdAt: clock.now,
            modifiedAt: clock.now
        )

        let dashboard = ProjectDashboard(project: project)
        #expect(dashboard.driftCount == 1)
    }
}
