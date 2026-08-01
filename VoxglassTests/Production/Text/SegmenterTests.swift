import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct SegmenterTests {

    @Test func segmentsSimpleDocument() {
        let doc = ExtractedDocument(
            sections: [
                ExtractedSection(
                    heading: "Chapter One",
                    blocks: [
                        ExtractedBlock(kind: .heading, text: "Chapter One", sourceRange: 0..<12),
                        ExtractedBlock(kind: .paragraph, text: "First paragraph.", sourceRange: 13..<30),
                        ExtractedBlock(kind: .paragraph, text: "Second paragraph.", sourceRange: 31..<49)
                    ],
                    sourceStart: 0
                )
            ],
            plainText: "Chapter One\n\nFirst paragraph.\n\nSecond paragraph."
        )

        let segmenter = Segmenter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let result = segmenter.segment(doc, options: SegmenterOptions(), ids: ids, clock: clock)

        #expect(result.chapters.count == 1)
        #expect(result.chapters[0].paragraphs.count == 3)
    }

    @Test func frontMatterChapterWhenNoHeading() {
        let doc = ExtractedDocument(
            sections: [
                ExtractedSection(
                    blocks: [
                        ExtractedBlock(kind: .paragraph, text: "Some preamble.", sourceRange: 0..<13)
                    ],
                    sourceStart: 0
                )
            ],
            plainText: "Some preamble."
        )

        let segmenter = Segmenter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let result = segmenter.segment(doc, ids: ids, clock: clock)

        #expect(result.chapters.count == 1)
        #expect(result.chapters[0].role == .frontMatter)
        #expect(result.chapters[0].title == "Front Matter")
    }

    @Test func sceneBreakMarksFollowingParagraph() {
        let doc = ExtractedDocument(
            sections: [
                ExtractedSection(
                    heading: "Chapter",
                    blocks: [
                        ExtractedBlock(kind: .heading, text: "Chapter", sourceRange: 0..<7),
                        ExtractedBlock(kind: .paragraph, text: "Before.", sourceRange: 8..<15),
                        ExtractedBlock(kind: .sceneBreak, text: "* * *", sourceRange: 16..<21),
                        ExtractedBlock(kind: .paragraph, text: "After.", sourceRange: 22..<28)
                    ],
                    sourceStart: 0
                )
            ],
            plainText: "Chapter\n\nBefore.\n\n* * *\n\nAfter."
        )

        let segmenter = Segmenter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let result = segmenter.segment(doc, ids: ids, clock: clock)

        let paragraphs = result.chapters[0].paragraphs
        let afterParagraph = paragraphs.last { $0.text == "After." }
        #expect(afterParagraph?.isSceneBreak == true)
    }

    @Test func estimatedDurationFromCharCount() {
        let doc = ExtractedDocument(
            sections: [
                ExtractedSection(
                    blocks: [
                        ExtractedBlock(kind: .paragraph, text: String(repeating: "x", count: 1450), sourceRange: 0..<1450)
                    ],
                    sourceStart: 0
                )
            ],
            plainText: String(repeating: "x", count: 1450)
        )

        let segmenter = Segmenter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let result = segmenter.segment(doc, ids: ids, clock: clock)

        #expect(abs(result.stats.estimatedDuration - 100.0) < 1.0)
    }

    @Test func statsAreCorrect() {
        let doc = ExtractedDocument(
            sections: [
                ExtractedSection(
                    heading: "One",
                    blocks: [
                        ExtractedBlock(kind: .heading, text: "One", sourceRange: 0..<3),
                        ExtractedBlock(kind: .paragraph, text: "AAA", sourceRange: 4..<7),
                        ExtractedBlock(kind: .paragraph, text: "BBBBB", sourceRange: 8..<13)
                    ],
                    sourceStart: 0
                ),
                ExtractedSection(
                    heading: "Two",
                    blocks: [
                        ExtractedBlock(kind: .heading, text: "Two", sourceRange: 14..<17),
                        ExtractedBlock(kind: .paragraph, text: "CCCCCCC", sourceRange: 18..<25)
                    ],
                    sourceStart: 14
                )
            ],
            plainText: "One\n\nAAA\n\nBBBBB\n\nTwo\n\nCCCCCCC"
        )

        let segmenter = Segmenter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let result = segmenter.segment(doc, ids: ids, clock: clock)

        #expect(result.stats.chapterCount == 2)
        #expect(result.stats.paragraphCount == 5)
        #expect(result.stats.longestParagraphChars == 7)
        #expect(result.stats.averageParagraphChars == 4)
    }

    @Test func emptyDocumentProducesWarning() {
        let doc = ExtractedDocument(
            sections: [],
            plainText: ""
        )

        let segmenter = Segmenter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let result = segmenter.segment(doc, ids: ids, clock: clock)

        #expect(result.stats.chapterCount == 0)
        #expect(result.stats.paragraphCount == 0)
        #expect(result.warnings.contains { $0.kind == .emptySection })
    }

    @Test func interiorHeadingsCreateChapters() {
        let doc = ExtractedDocument(
            sections: [
                ExtractedSection(
                    blocks: [
                        ExtractedBlock(kind: .heading, text: "CHAPTER I", sourceRange: 0..<9, headingLevel: 1),
                        ExtractedBlock(kind: .paragraph, text: "First chapter prose.", sourceRange: 10..<30),
                        ExtractedBlock(kind: .heading, text: "CHAPTER II", sourceRange: 31..<41, headingLevel: 1),
                        ExtractedBlock(kind: .paragraph, text: "Second chapter prose.", sourceRange: 42..<64)
                    ],
                    sourceStart: 0
                )
            ],
            plainText: "CHAPTER I\n\nFirst chapter prose.\n\nCHAPTER II\n\nSecond chapter prose."
        )

        let segmenter = Segmenter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let result = segmenter.segment(doc, ids: ids, clock: clock)

        #expect(result.chapters.count == 2)
        #expect(result.chapters[0].title == "CHAPTER I")
        #expect(result.chapters[1].title == "CHAPTER II")
        #expect(result.chapters[0].paragraphs.count == 2)
        #expect(result.chapters[1].paragraphs.count == 2)
    }

    @Test func reimportPreservesIDsAndTakes() {
        let textOne = "The morning sun rose over the quiet village, casting long shadows across the empty streets."
        let textTwo = "Chapter three began with a knock at the door, and the old clock in the hall struck nine times."
        let textThree = "By evening, the travelers had crossed the river and reached the safety of the forest's edge."
        let textTwoEdited = "Chapter three began with a soft knock at the door, and the old clock in the hall struck nine times."

        let doc = ExtractedDocument(
            sections: [
                ExtractedSection(
                    blocks: [
                        ExtractedBlock(kind: .paragraph, text: textOne, sourceRange: 0..<textOne.count),
                        ExtractedBlock(kind: .paragraph, text: textTwo, sourceRange: (textOne.count + 2)..<(textOne.count + 2 + textTwo.count)),
                        ExtractedBlock(kind: .paragraph, text: textThree, sourceRange: (textOne.count + textTwo.count + 4)..<(textOne.count + textTwo.count + 4 + textThree.count))
                    ],
                    sourceStart: 0
                )
            ],
            plainText: textOne + "\n\n" + textTwo + "\n\n" + textThree
        )

        let segmenter = Segmenter()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let first = segmenter.segment(doc, ids: ids, clock: clock)
        let firstChapter = first.chapters[0]
        let firstIDs = firstChapter.paragraphs.map(\.id)
        let takesForSecond = Take(
            id: UUID(), paragraphID: firstChapter.paragraphs[1].id,
            assetRef: AudioAssetReference(sha256: "abc", relativePath: "Audio/Original/abc.wav", byteCount: 3, contentType: "audio/wav"),
            origin: .recorded, recordedAt: Date(), duration: 1.5,
            format: AudioFormatDescription(sampleRate: 48000, channels: 1, bitDepth: 16, codec: "pcm"),
            textHashAtRecording: "hash"
        )

        var project = AudiobookProject(
            id: UUID(), metadata: BookMetadata(title: "T", author: "A", narrator: "N"),
            profile: ProductionProfile(purpose: .publicDomainCommunity, recording: RecordingDefaults(), assembly: AssemblySettings(), intendedDestination: .librivox),
            chapters: first.chapters
        )
        project.chapters[0].paragraphs[1].takes = [takesForSecond]
        project.chapters[0].paragraphs[1].selectedTakeID = takesForSecond.id

        let editedDoc = ExtractedDocument(
            sections: [
                ExtractedSection(
                    blocks: [
                        ExtractedBlock(kind: .paragraph, text: textOne, sourceRange: 0..<textOne.count),
                        ExtractedBlock(kind: .paragraph, text: textTwoEdited, sourceRange: (textOne.count + 2)..<(textOne.count + 2 + textTwoEdited.count)),
                        ExtractedBlock(kind: .paragraph, text: textThree, sourceRange: (textOne.count + textTwo.count + 4)..<(textOne.count + textTwo.count + 4 + textThree.count))
                    ],
                    sourceStart: 0
                )
            ],
            plainText: textOne + "\n\n" + textTwoEdited + "\n\n" + textThree
        )

        let second = segmenter.segment(editedDoc, existing: project, ids: ids, clock: clock)
        let secondIDs = second.chapters[0].paragraphs.map(\.id)

        #expect(secondIDs[0] == firstIDs[0])
        #expect(secondIDs[2] == firstIDs[2])

        let preserved = second.chapters[0].paragraphs.first { $0.id == firstIDs[1] }
        #expect(preserved?.takes.count == 1)
        #expect(preserved?.takes.first?.id == takesForSecond.id)
    }
}
