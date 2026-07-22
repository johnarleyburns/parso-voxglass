import XCTest
import VoxglassCore

final class NarrationClassifierTests: XCTestCase {

    func testSoloFromSingleCleanName() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["Elizabeth Klett"]), .solo)
    }

    func testSoloFromExpatriate() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["Expatriate"]), .solo)
    }

    func testSoloFromCarlBanks() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["Carl Banks"]), .solo)
    }

    func testSoloFromGregMargarite() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["Gregg Margarite"]), .solo)
    }

    func testMixedOrUnknownFromMultipleNames() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["Jane Doe", "John Smith"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromEmptyArray() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: []), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromVolunteers() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["volunteers"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromCast() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["cast"]), .mixedOrUnknown)
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["full cast"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromVarious() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["various"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromGroup() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["group"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromDramaticReading() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["dramatic reading"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromUnknown() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["unknown"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromAnonymous() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["anonymous"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromCollaborative() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["collaborative"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromLibriVoxVolunteers() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["LibriVox volunteers"]), .mixedOrUnknown)
    }

    func testMixedOrUnknownFromMultipleReaders() {
        XCTAssertEqual(NarrationClassifier.classify(narrators: ["multiple readers"]), .mixedOrUnknown)
    }

    func testDescriptionSoloExtractedNarrator() {
        XCTAssertEqual(
            NarrationClassifier.classify(description: "Read by Elizabeth Klett. A classic tale."),
            .solo
        )
    }

    func testDescriptionMultipleNarrators() {
        XCTAssertEqual(
            NarrationClassifier.classify(description: "Read by Jane Doe and John Smith"),
            .mixedOrUnknown
        )
    }

    func testDescriptionVolunteers() {
        XCTAssertEqual(
            NarrationClassifier.classify(description: "Read by LibriVox volunteers"),
            .mixedOrUnknown
        )
    }

    func testDescriptionNoReaderMetadata() {
        XCTAssertEqual(
            NarrationClassifier.classify(description: nil),
            .mixedOrUnknown
        )
        XCTAssertEqual(
            NarrationClassifier.classify(description: ""),
            .mixedOrUnknown
        )
        XCTAssertEqual(
            NarrationClassifier.classify(description: "A wonderful audiobook."),
            .mixedOrUnknown
        )
    }

    func testChapterNarratorsSingleSolo() {
        XCTAssertEqual(
            NarrationClassifier.classify(chapterNarrators: ["Elizabeth Klett"], bookNarrators: ["Elizabeth Klett"]),
            .solo
        )
    }

    func testChapterNarratorsMultipleReaders() {
        XCTAssertEqual(
            NarrationClassifier.classify(chapterNarrators: ["Jane Doe", "John Smith"], bookNarrators: []),
            .mixedOrUnknown
        )
    }

    func testChapterNarratorsEmptyFallsBackToBook() {
        XCTAssertEqual(
            NarrationClassifier.classify(chapterNarrators: [], bookNarrators: ["Elizabeth Klett"]),
            .solo
        )
    }

    func testNarrationKindOnBook() {
        let soloBook = Book(title: "Test", authors: [], narrators: ["Jane Doe"], sourceID: UUID())
        XCTAssertEqual(soloBook.narrationKind, .solo)

        let mixedBook = Book(title: "Test", authors: [], narrators: ["Jane Doe", "John Smith"], sourceID: UUID())
        XCTAssertEqual(mixedBook.narrationKind, .mixedOrUnknown)

        let volunteerBook = Book(title: "Test", authors: [], narrators: ["volunteers"], sourceID: UUID())
        XCTAssertEqual(volunteerBook.narrationKind, .mixedOrUnknown)

        let emptyBook = Book(title: "Test", authors: [], narrators: [], sourceID: UUID())
        XCTAssertEqual(emptyBook.narrationKind, .mixedOrUnknown)
    }

    func testNarrationKindOnBookWithChapters() {
        let soloBook = Book(title: "Test", authors: [], narrators: ["Jane Doe"], sourceID: UUID())
        let bw = BookWithChapters(book: soloBook, chapters: [])
        XCTAssertEqual(bw.narrationKind, .solo)
    }
}
