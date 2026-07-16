import XCTest
@testable import VoxglassCore

final class ModelBehaviorTests: XCTestCase {
    func testPlaybackPositionClampsToDuration() {
        let position = PlaybackPosition(
            bookID: UUID(),
            chapterID: UUID(),
            position: 90,
            duration: 30
        )

        XCTAssertEqual(position.position, 30)
    }

    func testPlaybackPositionDoesNotGoNegative() {
        let position = PlaybackPosition(
            bookID: UUID(),
            chapterID: UUID(),
            position: -12,
            duration: 30
        )

        XCTAssertEqual(position.position, 0)
    }

    func testChaptersUseNaturalOrderWithinIndex() {
        let bookID = UUID()
        let chapters = [
            Chapter(bookID: bookID, title: "Chapter 10", index: 0),
            Chapter(bookID: bookID, title: "Chapter 2", index: 0),
            Chapter(bookID: bookID, title: "Chapter 1", index: 0)
        ]

        XCTAssertEqual(chapters.naturallySorted().map(\.title), ["Chapter 1", "Chapter 2", "Chapter 10"])
    }

    func testBookAuthorLineFallsBackWhenMissing() {
        let book = Book(title: "Test Book", authors: [], sourceID: UUID())

        XCTAssertEqual(book.authorLine, "Unknown author")
    }
}

