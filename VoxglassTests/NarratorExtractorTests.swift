import Testing
@testable import VoxglassCore

@Suite struct NarratorExtractorTests {

    @Test func readByPhrase() {
        #expect(NarratorExtractor.extract(from: "A classic tale. Read by Jane Doe.") == ["Jane Doe"])
    }

    @Test func narratedByWithMultipleNames() {
        #expect(NarratorExtractor.extract(from: "Narrated by Jane Doe and John Smith") == ["Jane Doe", "John Smith"])
    }

    @Test func narratorLabelWithCommaSeparatedList() {
        #expect(NarratorExtractor.extract(from: "Narrator: Jane Doe, John Smith, Amy Lee") == ["Jane Doe", "John Smith", "Amy Lee"])
    }

    @Test func readerLabel() {
        #expect(NarratorExtractor.extract(from: "Reader: Gregg Margarite") == ["Gregg Margarite"])
    }

    @Test func deduplicatesCaseInsensitively() {
        #expect(NarratorExtractor.extract(from: "Read by Jane Doe and jane doe") == ["Jane Doe"])
    }

    @Test func rejectsPlaceholderNames() {
        #expect(NarratorExtractor.extract(from: "Read by Various").isEmpty)
        #expect(NarratorExtractor.extract(from: "Narrated by unknown").isEmpty)
    }

    @Test func emptyAndNilInputs() {
        #expect(NarratorExtractor.extract(from: nil).isEmpty)
        #expect(NarratorExtractor.extract(from: "").isEmpty)
        #expect(NarratorExtractor.extract(from: "No narrator info here at all.").isEmpty)
    }

    @Test func stopsAtSentenceBoundary() {
        #expect(NarratorExtractor.extract(from: "Read by Jane Doe. This book is great.") == ["Jane Doe"])
    }
}
