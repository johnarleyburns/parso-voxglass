import XCTest
@testable import VoxglassCore

final class NarratorExtractorTests: XCTestCase {

    func testReadByPhrase() {
        XCTAssertEqual(NarratorExtractor.extract(from: "A classic tale. Read by Jane Doe."), ["Jane Doe"])
    }

    func testNarratedByWithMultipleNames() {
        XCTAssertEqual(
            NarratorExtractor.extract(from: "Narrated by Jane Doe and John Smith"),
            ["Jane Doe", "John Smith"]
        )
    }

    func testNarratorLabelWithCommaSeparatedList() {
        XCTAssertEqual(
            NarratorExtractor.extract(from: "Narrator: Jane Doe, John Smith, Amy Lee"),
            ["Jane Doe", "John Smith", "Amy Lee"]
        )
    }

    func testReaderLabel() {
        XCTAssertEqual(NarratorExtractor.extract(from: "Reader: Gregg Margarite"), ["Gregg Margarite"])
    }

    func testDeduplicatesCaseInsensitively() {
        XCTAssertEqual(
            NarratorExtractor.extract(from: "Read by Jane Doe and jane doe"),
            ["Jane Doe"]
        )
    }

    func testRejectsPlaceholderNames() {
        XCTAssertTrue(NarratorExtractor.extract(from: "Read by Various").isEmpty)
        XCTAssertTrue(NarratorExtractor.extract(from: "Narrated by unknown").isEmpty)
    }

    func testEmptyAndNilInputs() {
        XCTAssertTrue(NarratorExtractor.extract(from: nil).isEmpty)
        XCTAssertTrue(NarratorExtractor.extract(from: "").isEmpty)
        XCTAssertTrue(NarratorExtractor.extract(from: "No narrator info here at all.").isEmpty)
    }

    func testStopsAtSentenceBoundary() {
        XCTAssertEqual(
            NarratorExtractor.extract(from: "Read by Jane Doe. This book is great."),
            ["Jane Doe"]
        )
    }
}
