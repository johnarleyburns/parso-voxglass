import XCTest
@testable import VoxglassCore

@MainActor
final class PlaybackCoordinatorBookmarkTests: XCTestCase {

    private let bookID = UUID()

    private func makeBook() -> BookWithChapters {
        let chapter1 = Chapter(bookID: bookID, title: "Ch 0", index: 0, duration: 100,
                               localURL: URL(fileURLWithPath: "/tmp/bkm-0.mp3"))
        let chapter2 = Chapter(bookID: bookID, title: "Ch 1", index: 1, duration: 100,
                               localURL: URL(fileURLWithPath: "/tmp/bkm-1.mp3"))
        return BookWithChapters(book: Book(id: bookID, title: "B", authors: ["A"], sourceID: UUID()),
                                chapters: [chapter1, chapter2])
    }

    private func makeCoordinator() -> (PlaybackCoordinator, FakeAudioEngine, SQLiteBookmarkStore) {
        let db = AppDatabase.makeTemporaryDatabase(named: "bm-coord-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let store = SQLiteBookmarkStore(database: db)
        let coordinator = PlaybackCoordinator(engine: engine, positionStore: SQLitePositionStore(database: db))
        coordinator.bookmarkStore = store
        engine.currentTime = 42
        return (coordinator, engine, store)
    }

    func testJumpToSameChapterSeeks() async {
        let (coordinator, engine, _) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()
        let bookmark = Bookmark(bookID: bookID, chapterID: coordinator.currentChapterID!, position: 30)
        await coordinator.jump(to: bookmark)
        XCTAssertTrue(engine.calls.contains(.seek(30)))
    }

    func testJumpToDifferentChapterLoads() async {
        let (coordinator, engine, _) = makeCoordinator()
        let book = makeBook()
        await coordinator.play(book)
        engine.reset()
        let otherChapter = book.chapters[1]
        let bookmark = Bookmark(bookID: bookID, chapterID: otherChapter.id, position: 55)
        await coordinator.jump(to: bookmark)
        let loads = engine.loadCalls
        XCTAssertFalse(loads.isEmpty, "A load(...) call must be issued for the new chapter")
        XCTAssertEqual(loads.first?.startTime, 55)
    }
}
