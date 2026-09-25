import Foundation
import Testing
@testable import VoxglassCore

@Suite struct ChapterDisplayTitleTests {
    @Test func normalizesTrackPartChapterAndGroupsRepeatedTitles() {
        let bookID = UUID()
        let chapters = [
            Chapter(bookID: bookID, title: "46 - Pt2 Ch6 The Basement", index: 0),
            Chapter(bookID: bookID, title: "47 - Pt2 Ch6 The Basement", index: 1),
            Chapter(bookID: bookID, title: "48 - Pt2 Ch6 The Basement", index: 2),
            Chapter(bookID: bookID, title: "49 - Pt2 Ch7 A Meeting (Section 1)", index: 3),
            Chapter(bookID: bookID, title: "50 - Pt2 Ch7 A Meeting (Section 2)", index: 4)
        ]
        let display = ChapterDisplayTitles.make(for: chapters)
        #expect(display[chapters[0].id]?.eyebrow == "Part 2 · Ch. 6 · 1 of 3")
        #expect(display[chapters[2].id]?.eyebrow == "Part 2 · Ch. 6 · 3 of 3")
        #expect(display[chapters[3].id]?.eyebrow == "Part 2 · Ch. 7 · 1 of 2")
        #expect(display[chapters[3].id]?.title == "A Meeting")
    }

    @Test func leavesUnstructuredTitlesUntouched() {
        let chapter = Chapter(bookID: UUID(), title: "Preface", index: 0)
        let display = ChapterDisplayTitles.make(for: [chapter])[chapter.id]
        #expect(display == ChapterDisplayTitle(eyebrow: nil, title: "Preface"))
    }
}
