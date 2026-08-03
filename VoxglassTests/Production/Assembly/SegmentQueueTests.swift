import Foundation
import Testing
import VoxglassCore

/// Spec §12.2: `SegmentQueueBuilder` turns a playback mode into an ordered list
/// of segments. Only paragraphs with a selected take produce segments;
/// listening modes apply chapter head/tail silence while review modes use a
/// tight 0.25 s turnaround.
@Suite struct SegmentQueueTests {

    private func makeTake(paragraphID: UUID, duration: TimeInterval = 5.0) -> Take {
        Take(
            id: UUID(),
            paragraphID: paragraphID,
            assetRef: AudioAssetReference(
                sha256: SHA256Hex.hex(Data(paragraphID.uuidString.utf8)),
                relativePath: "Audio/Original/ab/cd/\(paragraphID.uuidString).wav",
                byteCount: 1000,
                contentType: "audio/wav"
            ),
            origin: .recorded,
            recordedAt: Date(timeIntervalSince1970: 0),
            duration: duration,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm_s24le"),
            textHashAtRecording: "hash"
        )
    }

    private func makeParagraph(_ id: UUID, ordinal: Int, text: String, take: Take?) -> Paragraph {
        Paragraph(
            id: id,
            ordinal: ordinal,
            text: text,
            textHash: SHA256Hex.hex(Data(text.utf8)),
            takes: take.map { [$0] } ?? [],
            selectedTakeID: take?.id,
            reviewState: .unreviewed
        )
    }

    /// Two chapters, three paragraphs each; the middle paragraphs of chapter 1
    /// are recorded, chapter 2 has two recorded paragraphs (one flagged, one
    /// needsPickup, one unrecorded).
    private func makeProject() -> AudiobookProject {
        var ids: [UUID] = []
        for _ in 0..<4 { ids.append(UUID()) }

        let a1 = makeTake(paragraphID: ids[0], duration: 4.0)
        let a2 = makeTake(paragraphID: ids[1], duration: 5.0)

        let ch1Paragraphs = [
            makeParagraph(ids[0], ordinal: 0, text: "Chapter 1 ¶ 1 (recorded)", take: a1),
            makeParagraph(ids[1], ordinal: 1, text: "Chapter 1 ¶ 2 (recorded)", take: a2),
            makeParagraph(UUID(), ordinal: 2, text: "Chapter 1 ¶ 3 (unrecorded)", take: nil),
        ]
        let ch1 = ProductionChapter(id: UUID(), ordinal: 0, title: "Chapter One", paragraphs: ch1Paragraphs)

        let b1 = makeTake(paragraphID: ids[2], duration: 3.0)
        let b2 = makeTake(paragraphID: ids[3], duration: 6.0)

        var pFlagged = makeParagraph(ids[2], ordinal: 0, text: "Chapter 2 ¶ 1 (flagged)", take: b1)
        pFlagged.reviewState = .flagged
        var pPickup = makeParagraph(ids[3], ordinal: 1, text: "Chapter 2 ¶ 2 (needs pickup)", take: b2)
        pPickup.reviewState = .needsPickup

        let ch2 = ProductionChapter(id: UUID(), ordinal: 1, title: "Chapter Two", paragraphs: [
            pFlagged, pPickup, makeParagraph(UUID(), ordinal: 2, text: "Chapter 2 ¶ 3 (unrecorded)", take: nil),
        ])

        return AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "Queue Test", author: "A", narrator: "N"),
            chapters: [ch1, ch2],
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private let settings = AssemblySettings(
        paragraphGap: 0.45,
        chapterHeadSilence: 0.75,
        chapterTailSilence: 1.5,
        sceneBreakExtraGap: 1.0,
        normalizeGapsFromTakeSilence: true
    )

    @Test func wholeBookIncludesOnlyRecordedParagraphsInDocumentOrder() {
        let project = makeProject()
        let segments = SegmentQueueBuilder().build(.wholeBook, from: project, settings: settings)

        // 4 recorded paragraphs total.
        #expect(segments.count == 4)
        // Ordered by chapter then paragraph ordinal.
        let ordinals = segments.map(\.globalOrdinal)
        #expect(ordinals == ordinals.sorted())
        #expect(segments[0].chapterID != segments[3].chapterID)
    }

    @Test func chapterModeRestrictsToOneChapter() {
        let project = makeProject()
        let ch2 = project.chapters[1]
        let segments = SegmentQueueBuilder().build(.chapter(ch2.id), from: project, settings: settings)
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.chapterID == ch2.id })
        #expect(segments.count == 2)
    }

    @Test func wholeBookAppliesHeadAndTailSilence() {
        // A single chapter with three recorded paragraphs gives a genuine
        // interior segment whose leading edge carries the paragraph gap.
        let ids = [UUID(), UUID(), UUID()]
        var paragraphs: [Paragraph] = []
        for (i, id) in ids.enumerated() {
            let take = makeTake(paragraphID: id, duration: Double(i + 2))
            var p = makeParagraph(id, ordinal: i, text: "Para \(i)", take: take)
            p.reviewState = i == 1 ? .flagged : .unreviewed
            paragraphs.append(p)
        }
        let chapter = ProductionChapter(id: UUID(), ordinal: 0, title: "Chapter One", paragraphs: paragraphs)
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "Silence Test", author: "A", narrator: "N"),
            chapters: [chapter],
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )

        let segments = SegmentQueueBuilder().build(.chapter(chapter.id), from: project, settings: settings)
        #expect(segments.count == 3)
        #expect(segments[0].leadingSilence == settings.chapterHeadSilence)
        #expect(segments[0].trailingSilence == 0)
        #expect(segments[1].leadingSilence == settings.paragraphGap)
        #expect(segments[1].trailingSilence == 0)
        #expect(segments[2].leadingSilence == settings.paragraphGap)
        #expect(segments[2].trailingSilence == settings.chapterTailSilence)
    }

    @Test func sceneBreakAddsExtraGap() {
        let project = makeProject()
        var ch1 = project.chapters[0]
        ch1.paragraphs[1].isSceneBreak = true
        var modified = project
        modified.chapters[0] = ch1

        let segments = SegmentQueueBuilder().build(.chapter(ch1.id), from: modified, settings: settings)
        let sceneSegment = segments.first { $0.paragraphID == ch1.paragraphs[1].id }
        #expect(sceneSegment?.leadingSilence == settings.paragraphGap + settings.sceneBreakExtraGap)
    }

    @Test func flaggedQueueContainsOnlyFlaggedRecordedParagraphs() {
        let project = makeProject()
        let segments = SegmentQueueBuilder().build(.flagged, from: project, settings: settings)
        #expect(segments.count == 1)
        #expect(segments[0].paragraphID == project.chapters[1].paragraphs[0].id)
    }

    @Test func reviewModesUseTightTurnaround() {
        let project = makeProject()
        let segments = SegmentQueueBuilder().build(.needsPickup, from: project, settings: settings)
        #expect(segments.count == 1)
        #expect(segments[0].leadingSilence == 0)
        #expect(segments[0].trailingSilence == 0.25)
    }

    @Test func paragraphRangeModeLimitsToRange() {
        let project = makeProject()
        let ch1 = project.chapters[0]
        let segments = SegmentQueueBuilder().build(
            .paragraphRange(chapterID: ch1.id, from: 0, to: 1),
            from: project,
            settings: settings
        )
        #expect(segments.allSatisfy { $0.chapterID == ch1.id })
        #expect(segments.count <= 2)
    }

    @Test func retailSampleStartsAtParagraphAndStaysInChapter() {
        let project = makeProject()
        let ch1 = project.chapters[0]
        let start = ch1.paragraphs[0].id
        let segments = SegmentQueueBuilder().build(
            .retailSample(startParagraph: start, maxDuration: 6.0),
            from: project,
            settings: settings
        )
        // ch1 has two recorded paragraphs (4 s and 5 s) starting at index 0 —
        // far less than the 60 s retail floor, so the whole run is returned.
        #expect(!segments.isEmpty)
        #expect(segments[0].paragraphID == start)
        #expect(segments.allSatisfy { $0.chapterID == ch1.id })
        let duration = segments.reduce(TimeInterval(0)) { acc, s in
            acc + (s.trim.upperBound - s.trim.lowerBound) + s.leadingSilence + s.trailingSilence
        }
        // 4 s + 5 s + head silence (0.75) + interior gap (0.45) + tail (1.5).
        #expect(duration == 11.7)
    }

    @Test func retailSampleWindowFloorDoesNotTruncateShortContent() {
        let project = makeProject()
        let ch1 = project.chapters[0]
        let start = ch1.paragraphs[0].id
        // A sub-60 s request clips to the 60 s floor, but content shorter than
        // the floor is returned in full — never truncated to the requested
        // (sub-60 s) length.
        let segments = SegmentQueueBuilder().build(
            .retailSample(startParagraph: start, maxDuration: 1.0),
            from: project,
            settings: settings
        )
        let duration = segments.reduce(TimeInterval(0)) { acc, s in
            acc + (s.trim.upperBound - s.trim.lowerBound) + s.leadingSilence + s.trailingSilence
        }
        #expect(duration == 11.7)
        #expect(segments.count == 2)
    }

    @Test func retailSampleWindowClipsAtTargetWhenContentIsLong() {
        // Six 12 s paragraphs = 72 s+ of content: a 60 s target must clip.
        let ids = [UUID(), UUID(), UUID(), UUID(), UUID(), UUID()]
        var paragraphs: [Paragraph] = []
        for (i, id) in ids.enumerated() {
            paragraphs.append(makeParagraph(id, ordinal: i, text: "Para \(i)", take: makeTake(paragraphID: id, duration: 12.0)))
        }
        let chapter = ProductionChapter(id: UUID(), ordinal: 0, title: "Chapter One", paragraphs: paragraphs)
        let project = AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "Long Book", author: "A", narrator: "N"),
            chapters: [chapter],
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
        let segments = SegmentQueueBuilder().build(
            .retailSample(startParagraph: ids[0], maxDuration: 60.0),
            from: project,
            settings: settings
        )
        let duration = segments.reduce(TimeInterval(0)) { acc, s in
            acc + (s.trim.upperBound - s.trim.lowerBound) + s.leadingSilence + s.trailingSilence
        }
        // 5 paragraphs of 12 s + head 0.75 + gaps: ≥ 60, under the full 6.
        #expect(duration >= 60)
        #expect(duration < 6 * 12)
        #expect(segments.count < 6)
    }
}
