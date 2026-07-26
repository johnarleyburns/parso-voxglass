import Testing
import Foundation
import VoxglassCore

@Suite struct NarrationClassifierTests {

    @Test func soloFromSingleCleanName() {
        #expect(NarrationClassifier.classify(narrators: ["Elizabeth Klett"]) == .solo)
    }

    @Test func soloFromExpatriate() {
        #expect(NarrationClassifier.classify(narrators: ["Expatriate"]) == .solo)
    }

    @Test func soloFromCarlBanks() {
        #expect(NarrationClassifier.classify(narrators: ["Carl Banks"]) == .solo)
    }

    @Test func soloFromGregMargarite() {
        #expect(NarrationClassifier.classify(narrators: ["Gregg Margarite"]) == .solo)
    }

    @Test func mixedOrUnknownFromMultipleNames() {
        #expect(NarrationClassifier.classify(narrators: ["Jane Doe", "John Smith"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromEmptyArray() {
        #expect(NarrationClassifier.classify(narrators: []) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromVolunteers() {
        #expect(NarrationClassifier.classify(narrators: ["volunteers"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromCast() {
        #expect(NarrationClassifier.classify(narrators: ["cast"]) == .mixedOrUnknown)
        #expect(NarrationClassifier.classify(narrators: ["full cast"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromVarious() {
        #expect(NarrationClassifier.classify(narrators: ["various"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromGroup() {
        #expect(NarrationClassifier.classify(narrators: ["group"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromDramaticReading() {
        #expect(NarrationClassifier.classify(narrators: ["dramatic reading"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromUnknown() {
        #expect(NarrationClassifier.classify(narrators: ["unknown"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromAnonymous() {
        #expect(NarrationClassifier.classify(narrators: ["anonymous"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromCollaborative() {
        #expect(NarrationClassifier.classify(narrators: ["collaborative"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromLibriVoxVolunteers() {
        #expect(NarrationClassifier.classify(narrators: ["LibriVox volunteers"]) == .mixedOrUnknown)
    }

    @Test func mixedOrUnknownFromMultipleReaders() {
        #expect(NarrationClassifier.classify(narrators: ["multiple readers"]) == .mixedOrUnknown)
    }

    @Test func descriptionSoloExtractedNarrator() {
        #expect(NarrationClassifier.classify(description: "Read by Elizabeth Klett. A classic tale.") == .solo)
    }

    @Test func descriptionMultipleNarrators() {
        #expect(NarrationClassifier.classify(description: "Read by Jane Doe and John Smith") == .mixedOrUnknown)
    }

    @Test func descriptionVolunteers() {
        #expect(NarrationClassifier.classify(description: "Read by LibriVox volunteers") == .mixedOrUnknown)
    }

    @Test func descriptionNoReaderMetadata() {
        #expect(NarrationClassifier.classify(description: nil) == .mixedOrUnknown)
        #expect(NarrationClassifier.classify(description: "") == .mixedOrUnknown)
        #expect(NarrationClassifier.classify(description: "A wonderful audiobook.") == .mixedOrUnknown)
    }

    @Test func chapterNarratorsSingleSolo() {
        #expect(NarrationClassifier.classify(chapterNarrators: ["Elizabeth Klett"], bookNarrators: ["Elizabeth Klett"]) == .solo)
    }

    @Test func chapterNarratorsMultipleReaders() {
        #expect(NarrationClassifier.classify(chapterNarrators: ["Jane Doe", "John Smith"], bookNarrators: []) == .mixedOrUnknown)
    }

    @Test func chapterNarratorsEmptyFallsBackToBook() {
        #expect(NarrationClassifier.classify(chapterNarrators: [], bookNarrators: ["Elizabeth Klett"]) == .solo)
    }

    @Test func narrationKindOnBook() {
        let soloBook = Book(title: "Test", authors: [], narrators: ["Jane Doe"], sourceID: UUID())
        #expect(soloBook.narrationKind == .solo)

        let mixedBook = Book(title: "Test", authors: [], narrators: ["Jane Doe", "John Smith"], sourceID: UUID())
        #expect(mixedBook.narrationKind == .mixedOrUnknown)

        let volunteerBook = Book(title: "Test", authors: [], narrators: ["volunteers"], sourceID: UUID())
        #expect(volunteerBook.narrationKind == .mixedOrUnknown)

        let emptyBook = Book(title: "Test", authors: [], narrators: [], sourceID: UUID())
        #expect(emptyBook.narrationKind == .mixedOrUnknown)
    }

    @Test func narrationKindOnBookWithChapters() {
        let soloBook = Book(title: "Test", authors: [], narrators: ["Jane Doe"], sourceID: UUID())
        let bw = BookWithChapters(book: soloBook, chapters: [])
        #expect(bw.narrationKind == .solo)
    }
}
