import Testing
import Foundation
@testable import VoxglassCore

@Suite struct ModelBehaviorTests {
    @Test func playbackPositionClampsToDuration() {
        let position = PlaybackPosition(
            bookID: UUID(),
            chapterID: UUID(),
            position: 90,
            duration: 30
        )

        #expect(position.position == 30)
    }

    @Test func playbackPositionDoesNotGoNegative() {
        let position = PlaybackPosition(
            bookID: UUID(),
            chapterID: UUID(),
            position: -12,
            duration: 30
        )

        #expect(position.position == 0)
    }

    @Test func chaptersUseNaturalOrderWithinIndex() {
        let bookID = UUID()
        let chapters = [
            Chapter(bookID: bookID, title: "Chapter 10", index: 0),
            Chapter(bookID: bookID, title: "Chapter 2", index: 0),
            Chapter(bookID: bookID, title: "Chapter 1", index: 0)
        ]

        #expect(chapters.naturallySorted().map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 10"])
    }

    @Test func bookAuthorLineFallsBackWhenMissing() {
        let book = Book(title: "Test Book", authors: [], sourceID: UUID())

        #expect(book.authorLine == "Unknown author")
    }
}

