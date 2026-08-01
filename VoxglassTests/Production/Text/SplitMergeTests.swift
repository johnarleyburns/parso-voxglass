import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct SplitMergeTests {

    func makeParagraph(_ id: UUID, _ text: String, ordinal: Int = 0, role: ParagraphRole = .body) -> Paragraph {
        Paragraph(
            id: id,
            ordinal: ordinal,
            text: text,
            textHash: TextNormalizer.hash(text),
            role: role,
            directionNote: "Speak softly",
            pronunciationRefs: [UUID()]
        )
    }

    @Test func splitPreservesFirstID() {
        let id = UUID()
        let paragraph = makeParagraph(id, "First sentence. Second sentence.", ordinal: 5)
        let splitter = ParagraphSplitter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let (first, second) = splitter.split(paragraph, atCharacterOffset: 16, ids: ids, clock: clock)

        #expect(first.id == id)
        #expect(second.id != id)
        #expect(first.ordinal == 5)
        #expect(second.ordinal == 6)
    }

    @Test func splitCopiesDirectionNotes() {
        let id = UUID()
        let paragraph = makeParagraph(id, "Hello world. Goodbye world.")
        let splitter = ParagraphSplitter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let (first, second) = splitter.split(paragraph, atCharacterOffset: 12, ids: ids, clock: clock)

        #expect(first.directionNote == "Speak softly")
        #expect(second.directionNote == "Speak softly")
    }

    @Test func splitCopiesPronunciationRefs() {
        let id = UUID()
        let ref = UUID()
        let paragraph = Paragraph(
            id: id,
            ordinal: 0,
            text: "First half. Second half.",
            textHash: TextNormalizer.hash("First half. Second half."),
            role: .body,
            pronunciationRefs: [ref]
        )
        let splitter = ParagraphSplitter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let (first, second) = splitter.split(paragraph, atCharacterOffset: 11, ids: ids, clock: clock)

        #expect(first.pronunciationRefs.contains(ref))
        #expect(second.pronunciationRefs.contains(ref))
    }

    @Test func mergeCombinesText() {
        let id1 = UUID(); let id2 = UUID()
        let a = makeParagraph(id1, "First part")
        let b = makeParagraph(id2, "Second part")
        let splitter = ParagraphSplitter()
        let clock = FixedClock()

        let merged = splitter.merge(a, b, clock: clock)

        #expect(merged.id == id1)
        #expect(merged.text == "First part\nSecond part")
    }

    @Test func mergeArchivesSecondTakes() {
        let assetRef = AudioAssetReference(sha256: "abc", relativePath: "test.wav", byteCount: 100, contentType: "audio/wav")
        let take1 = Take(
            id: UUID(), paragraphID: UUID(), assetRef: assetRef, origin: .recorded,
            recordedAt: Date(), duration: 1.0, format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: "hash1"
        )
        let take2 = Take(
            id: UUID(), paragraphID: UUID(), assetRef: assetRef, origin: .recorded,
            recordedAt: Date(), duration: 2.0, format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: "hash2"
        )

        let a = Paragraph(id: UUID(), ordinal: 0, text: "A", textHash: "h1", takes: [take1])
        let b = Paragraph(id: UUID(), ordinal: 1, text: "B", textHash: "h2", takes: [take2])
        let splitter = ParagraphSplitter()
        let clock = FixedClock()

        let merged = splitter.merge(a, b, clock: clock)

        #expect(merged.takes.count == 2)
        #expect(merged.takes.contains { $0.isArchived })
    }

    @Test func mergeTakesWorseReviewState() {
        let a = Paragraph(id: UUID(), ordinal: 0, text: "A", textHash: "h1", reviewState: .approved)
        let b = Paragraph(id: UUID(), ordinal: 1, text: "B", textHash: "h2", reviewState: .needsPickup)
        let splitter = ParagraphSplitter()
        let clock = FixedClock()

        let merged = splitter.merge(a, b, clock: clock)

        #expect(merged.reviewState == .needsPickup)
    }

    @Test func splitSecondHalfIsUnreviewed() {
        let id = UUID()
        let paragraph = Paragraph(
            id: id, ordinal: 0, text: "First half. Second half.",
            textHash: TextNormalizer.hash("First half. Second half."),
            role: .body, reviewState: .approved
        )
        let splitter = ParagraphSplitter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let (first, second) = splitter.split(paragraph, atCharacterOffset: 11, ids: ids, clock: clock)

        #expect(first.reviewState == .approved)
        #expect(second.reviewState == .unreviewed)
    }

    @Test func splitLeavesTakesOnFirstHalfOnly() {
        let take = Take(
            id: UUID(), paragraphID: UUID(),
            assetRef: AudioAssetReference(sha256: "abc", relativePath: "test.wav", byteCount: 100, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1.0,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: "hash"
        )
        let paragraph = Paragraph(
            id: UUID(), ordinal: 0, text: "First half. Second half.",
            textHash: TextNormalizer.hash("First half. Second half."),
            takes: [take], selectedTakeID: take.id, reviewState: .approved
        )
        let splitter = ParagraphSplitter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let (first, second) = splitter.split(paragraph, atCharacterOffset: 11, ids: ids, clock: clock)

        #expect(first.takes.count == 1)
        #expect(first.takes.first?.id == take.id)
        #expect(first.selectedTakeID == take.id)
        #expect(second.takes.isEmpty)
        #expect(second.selectedTakeID == nil)
    }

    @Test func mergeUndoRestoresExactly() {
        let take = Take(
            id: UUID(), paragraphID: UUID(),
            assetRef: AudioAssetReference(sha256: "abc", relativePath: "test.wav", byteCount: 100, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1.0,
            format: AudioFormatDescription(sampleRate: 44100, channels: 1, codec: "pcm"),
            textHashAtRecording: "hash"
        )
        let original = Paragraph(
            id: UUID(), ordinal: 0, text: "First half. Second half.",
            textHash: TextNormalizer.hash("First half. Second half."),
            directionNote: "Speak softly",
            takes: [take], selectedTakeID: take.id, reviewState: .approved
        )
        let splitter = ParagraphSplitter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let (first, second) = splitter.split(original, atCharacterOffset: 11, ids: ids, clock: clock)
        let merged = splitter.merge(first, second, clock: clock)

        // Merge keeps the first paragraph's ID, takes and selected take —
        // the properties an undo record relies on.
        #expect(merged.id == original.id)
        #expect(merged.takes.count == 1)
        #expect(merged.takes.first?.id == take.id)
        #expect(merged.selectedTakeID == take.id)
        #expect(merged.text.contains("First half."))
        #expect(merged.text.contains("Second half."))
        #expect(merged.pronunciationRefs == original.pronunciationRefs)
    }
}
