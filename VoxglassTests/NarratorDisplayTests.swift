import Testing
import Foundation
@testable import VoxglassCore

@Suite struct NarratorDisplayTests {

    @Test func chapterLineReturnsNilWhenBookHasOnlyOneNarrator() {
        let chapter = Chapter(
            id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
            narrators: ["Alice"]
        )

        #expect(NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: ["Alice"]) == nil)  // Should return nil when only one narrator reads the whole book
    }

    @Test func chapterLineReturnsNarratorWhenMultiNarratorBook() {
        let chapter = Chapter(
            id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
            narrators: ["Alice"]
        )

        #expect(NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: ["Alice", "Bob"]) == "Alice")  // Should return the chapter's narrator when book has multiple narrators
    }

    @Test func chapterLineReturnsNilWhenChapterHasNoNarrators() {
        let chapter = Chapter(
            id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0
        )

        #expect(NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: ["Alice", "Bob"]) == nil)  // Should return nil when chapter has no narrators regardless of book narrators
    }

    @Test func chapterLineJoinsMultipleNarratorsForChapter() {
        let chapter = Chapter(
            id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
            narrators: ["Alice", "Bob"]
        )

        #expect(NarratorDisplay.chapterLine(chapter: chapter, bookNarrators: ["Alice", "Bob", "Charlie"]) == "Alice, Bob")  // Should join multiple chapter narrators with comma
    }
}
