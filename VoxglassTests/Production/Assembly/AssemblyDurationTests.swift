import Foundation
import Testing
import VoxglassCore

/// Spec §12.4 / §15.4: assembly durations are the sum of trimmed take
/// durations plus configured silence; and the S6 acceptance — changing one
/// paragraph invalidates exactly one chapter render — is proven by diffing
/// render cache keys before and after the change.
@Suite struct AssemblyDurationTests {

    private func segment(_ id: UUID, trim: Range<TimeInterval>, leading: TimeInterval = 0, trailing: TimeInterval = 0) -> PlaybackSegment {
        PlaybackSegment(
            paragraphID: id,
            chapterID: UUID(),
            globalOrdinal: 0,
            assetRef: AudioAssetReference(sha256: "sha", relativePath: "p.wav", byteCount: 1, contentType: "audio/wav"),
            trim: trim,
            leadingSilence: leading,
            trailingSilence: trailing,
            text: ""
        )
    }

    @Test func totalDurationSumsTrimmedAudioAndSilence() {
        let a = UUID()
        let b = UUID()
        let segments = [
            segment(a, trim: 0.0..<4.0, leading: 0.75, trailing: 0.45),
            segment(b, trim: 0.5..<5.5, leading: 0.45, trailing: 1.5),
        ]
        // 0.75 + 4.0 + 0.45 + 0.45 + 5.0 + 1.5
        #expect(AssemblyDuration.duration(of: segments) == 12.15)
    }

    @Test func paragraphOffsetsAreMonotonic() {
        let a = UUID()
        let b = UUID()
        let segments = [
            segment(a, trim: 0.0..<4.0, leading: 0.5, trailing: 0.5),
            segment(b, trim: 0.0..<3.0, leading: 0.5, trailing: 0.5),
        ]
        let timing = AssemblyDuration.compute(segments: segments)
        let aStart = timing.paragraphStart[a]
        let aEnd = timing.paragraphEnd[a]
        let bStart = timing.paragraphStart[b]
        #expect(aStart == 0.5)
        #expect(aEnd == 4.5)
        #expect(bStart == 5.5)
        #expect(timing.totalDuration == 9.0)
    }

    @Test func emptySegmentsProduceZeroDuration() {
        #expect(AssemblyDuration.duration(of: []) == 0)
    }

    // MARK: - Render invalidation

    @Test func changingOneParagraphChangesExactlyOneChapterRenderKey() {
        let settings = AssemblySettings(
            paragraphGap: 0.45,
            chapterHeadSilence: 0.75,
            chapterTailSilence: 1.5,
            sceneBreakExtraGap: 1.0,
            normalizeGapsFromTakeSilence: true
        )
        let format = AudioSpec(container: .caf, codec: .pcm, sampleRate: 48_000, channels: 1)
        let project = makeTwoChapterProject()

        let ch1 = project.chapters[0]
        let ch2 = project.chapters[1]

        func key(_ chapter: ProductionChapter) -> String {
            let segments = SegmentQueueBuilder().build(.chapter(chapter.id), from: project, settings: settings)
            return RenderCacheKey.key(chapterID: chapter.id, segments: segments, settings: settings, format: format)
        }

        let before1 = key(ch1)
        let before2 = key(ch2)

        // Re-record paragraph 0 of chapter 1 with a different take duration.
        var modified = project
        let para = modified.chapters[0].paragraphs[0]
        var updated = para
        let newTake = Take(
            id: UUID(),
            paragraphID: para.id,
            assetRef: para.takes[0].assetRef,
            origin: .recorded,
            recordedAt: Date(),
            duration: 8.0,
            format: para.takes[0].format,
            textHashAtRecording: para.takes[0].textHashAtRecording
        )
        updated.takes = [newTake]
        updated.selectedTakeID = newTake.id
        modified.chapters[0].paragraphs[0] = updated

        let after1 = SegmentQueueBuilder()
            .build(.chapter(ch1.id), from: modified, settings: settings)
        let after2 = SegmentQueueBuilder()
            .build(.chapter(ch2.id), from: modified, settings: settings)

        let newKey1 = RenderCacheKey.key(chapterID: ch1.id, segments: after1, settings: settings, format: format)
        let newKey2 = RenderCacheKey.key(chapterID: ch2.id, segments: after2, settings: settings, format: format)

        #expect(newKey1 != before1)
        #expect(newKey2 == before2)
    }

    private func makeTwoChapterProject() -> AudiobookProject {
        var ch1Paras: [Paragraph] = []
        var ch2Paras: [Paragraph] = []
        for i in 0..<2 {
            let pid = UUID()
            let take = Take(
                id: UUID(),
                paragraphID: pid,
                assetRef: AudioAssetReference(sha256: "s\(i)", relativePath: "p\(i).wav", byteCount: 10, contentType: "audio/wav"),
                origin: .recorded,
                recordedAt: Date(),
                duration: 5.0,
                format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
                textHashAtRecording: "h"
            )
            ch1Paras.append(Paragraph(id: pid, ordinal: i, text: "t\(i)", textHash: "h", takes: [take], selectedTakeID: take.id))
        }
        for i in 0..<2 {
            let pid = UUID()
            let take = Take(
                id: UUID(),
                paragraphID: pid,
                assetRef: AudioAssetReference(sha256: "s\(i)", relativePath: "p\(i).wav", byteCount: 10, contentType: "audio/wav"),
                origin: .recorded,
                recordedAt: Date(),
                duration: 5.0,
                format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
                textHashAtRecording: "h"
            )
            ch2Paras.append(Paragraph(id: pid, ordinal: i, text: "t\(i)", textHash: "h", takes: [take], selectedTakeID: take.id))
        }
        return AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "Two Chapter", author: "A", narrator: "N"),
            chapters: [
                ProductionChapter(id: UUID(), ordinal: 0, title: "Ch1", paragraphs: ch1Paras),
                ProductionChapter(id: UUID(), ordinal: 1, title: "Ch2", paragraphs: ch2Paras),
            ],
            createdAt: Date(),
            modifiedAt: Date()
        )
    }
}
