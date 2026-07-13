import XCTest
@testable import Voxglass

final class NarratorDisplayTests: XCTestCase {

    func testChapterLineReturnsNilWhenBookHasOnlyOneNarrator() {
        let chapter = Chapter(
            id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
            narrators: ["Alice"]
        )

        XCTAssertNil(NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: ["Alice"]),
                     "Should return nil when only one narrator reads the whole book")
    }

    func testChapterLineReturnsNarratorWhenMultiNarratorBook() {
        let chapter = Chapter(
            id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
            narrators: ["Alice"]
        )

        XCTAssertEqual(NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: ["Alice", "Bob"]),
                       "Alice",
                       "Should return the chapter's narrator when book has multiple narrators")
    }

    func testChapterLineReturnsNilWhenChapterHasNoNarrators() {
        let chapter = Chapter(
            id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0
        )

        XCTAssertNil(NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: ["Alice", "Bob"]),
                     "Should return nil when chapter has no narrators regardless of book narrators")
    }

    func testChapterLineJoinsMultipleNarratorsForChapter() {
        let chapter = Chapter(
            id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
            narrators: ["Alice", "Bob"]
        )

        XCTAssertEqual(NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: ["Alice", "Bob", "Charlie"]),
                       "Alice, Bob",
                       "Should join multiple chapter narrators with comma")
    }
}
