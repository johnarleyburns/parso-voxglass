import Foundation
import Testing
import VoxglassCore

@Suite struct ReidentificationTests {

    func makeParagraph(_ id: UUID, _ text: String, ordinal: Int = 0) -> Paragraph {
        Paragraph(
            id: id,
            ordinal: ordinal,
            text: text,
            textHash: TextNormalizer.hash(text),
            role: .body
        )
    }

    func makeBlock(_ text: String, start: Int = 0) -> ExtractedBlock {
        ExtractedBlock(kind: .paragraph, text: text, sourceRange: start..<(start + text.count))
    }

    @Test func exactMatchPreservesID() {
        let existing = [
            makeParagraph(UUID(), "Hello world"),
            makeParagraph(UUID(), "Goodbye world")
        ]
        let incoming = [
            makeBlock("Hello world"),
            makeBlock("Goodbye world")
        ]

        let report = ParagraphReidentifier().match(existing: existing, incoming: incoming)

        #expect(report.assignments[0] == existing[0].id)
        #expect(report.assignments[1] == existing[1].id)
        #expect(report.newIndices.isEmpty)
        #expect(report.retiredIDs.isEmpty)
    }

    @Test func newContentGetsNewID() {
        let existing = [
            makeParagraph(UUID(), "Original text")
        ]
        let incoming = [
            makeBlock("Some new text")
        ]

        let report = ParagraphReidentifier().match(existing: existing, incoming: incoming)

        #expect(report.newIndices.contains(0))
        #expect(report.retiredIDs.contains(existing[0].id))
    }

    @Test func cosmeticChangeDetected() {
        let id = UUID()
        let existing = [
            makeParagraph(id, "Hello world")
        ]
        let incoming = [
            makeBlock("Hello, world!")
        ]

        let report = ParagraphReidentifier().match(existing: existing, incoming: incoming)

        #expect(report.assignments[0] == id)
        #expect(report.driftedIDs[id] != nil)
    }

    @Test func identityKeyMatchesDespitePunctuation() {
        let id = UUID()
        let existing = [
            makeParagraph(id, "The quick brown fox")
        ]
        let incoming = [
            makeBlock("The quick, brown fox!")
        ]

        let report = ParagraphReidentifier().match(existing: existing, incoming: incoming)

        #expect(report.assignments[0] == id)
    }

    @Test func driftedIndicesReported() {
        let id = UUID()
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 5) + "and then the old brown cat sat quietly on the soft woven mat."
        let existing = [makeParagraph(id, text)]
        let incoming = [
            makeBlock(String(repeating: "the quick brown fox jumps over the lazy dog ", count: 5) + "and then the old brown cat sat quietly on the thick woven mat.")
        ]

        let report = ParagraphReidentifier().match(existing: existing, incoming: incoming)

        #expect(report.driftedIDs[id] != nil)
    }

    @Test func large10KParagraphReimport() {
        var existing: [Paragraph] = []
        var incoming: [ExtractedBlock] = []

        for i in 0..<10_000 {
            let id = UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", i))") ?? UUID()
            let text = "This is the lengthy content of paragraph number \(i) which contains many words to ensure that jaccard similarity computations are representative of real world paragraph structures and lengths for audiobook productions."
            existing.append(makeParagraph(id, text, ordinal: i))
            if i == 500 {
                incoming.append(makeBlock("This is the lengthy content of paragraph number \(i) which contains many words to ensure that jaccard similarity computations are REPRESENTATIVE of real world paragraph structures and lengths for audiobook productions."))
            } else {
                incoming.append(makeBlock(text))
            }
        }

        let start = Date()
        let report = ParagraphReidentifier().match(existing: existing, incoming: incoming)
        let elapsed = Date().timeIntervalSince(start)

        #expect(report.assignments.count >= 9_999)
        #expect(report.driftedIDs.count == 1)
        #expect(elapsed < 8.0)
    }

    @Test func insertionKeepsLaterParagraphsMatched() {
        let existing = (0..<5).map { makeParagraph(UUID(), "Original paragraph number \($0) with enough content to be unique in the matching pass over the whole document sequence.", ordinal: $0) }
        var incoming = (0..<5).map { makeBlock("Original paragraph number \($0) with enough content to be unique in the matching pass over the whole document sequence.") }
        incoming.insert(makeBlock("A brand new inserted paragraph that was not in the original edition at all and has no counterpart anywhere."), at: 2)

        let report = ParagraphReidentifier().match(existing: existing, incoming: incoming)

        #expect(report.newIndices.contains(2))
        #expect(report.assignments[0] == existing[0].id)
        #expect(report.assignments[1] == existing[1].id)
        #expect(report.assignments[3] == existing[2].id)
        #expect(report.assignments[4] == existing[3].id)
        #expect(report.assignments[5] == existing[4].id)
        #expect(report.retiredIDs.isEmpty)
    }

    @Test func paragraphEditedBeyondThresholdBecomesNewAndRetired() {
        let existing = [makeParagraph(UUID(), "The first paragraph of the chapter is a fairly long sentence with many words in it that the narrator will read aloud carefully.")]
        let incoming = [makeBlock("A completely different replacement paragraph that shares almost no words or structure with the original text that was recorded before the edit happened.")]

        let report = ParagraphReidentifier().match(existing: existing, incoming: incoming)

        #expect(report.retiredIDs.contains(existing[0].id))
        #expect(report.newIndices.contains(0))
        #expect(report.assignments.isEmpty)
    }
}
