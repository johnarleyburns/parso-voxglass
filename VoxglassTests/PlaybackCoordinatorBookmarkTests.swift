import XCTest
@testable import Voxglass

/// Bookmark call-log assertions through the coordinator (P0-3).
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

    func testAddBookmarkCapturesCurrentTime() async throws {
        let (coordinator, engine, store) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.currentTime = 87
        coordinator.addBookmark()
        try await Task.sleep(nanoseconds: 100_000_000)   // let the Task in addBookmark complete
        let bms = try await store.bookmarks(forBookID: bookID)
        XCTAssertEqual(bms.first?.position, 87, "addBookmark captures engine.currentTime")
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

    func testBookmarksAreFree() async throws {
        EntitlementCache.shared.setTestEntitlement(false)
        defer { EntitlementCache.shared.setTestEntitlement(nil) }
        let db = AppDatabase.makeTemporaryDatabase(named: "bm-free-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let store = SQLiteBookmarkStore(database: db)
        let coordinator = PlaybackCoordinator(engine: engine, positionStore: SQLitePositionStore(database: db))
        coordinator.bookmarkStore = store
        await coordinator.play(makeBook())
        engine.currentTime = 12
        coordinator.addBookmark()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bms = try await store.bookmarks(forBookID: bookID)
        XCTAssertEqual(bms.count, 1, "Bookmark CRUD must work free-tier")
    }
}
