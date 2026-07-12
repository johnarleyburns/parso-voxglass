import XCTest
@testable import Voxglass

@MainActor
final class NowPlayingFavoriteTests: XCTestCase {

    func testDerivationPrefersLiveStoreOverStaleSessionSnapshot() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "nowplaying-fav")
        let repository = LibraryRepository(database: database)
        let seeded = try await seedBook(in: database, title: "Now Playing Book")

        let store = LibraryStore(repository: repository)
        await store.refresh()

        // Session snapshot captured while the book was NOT a favorite (stale).
        let staleBook = store.book(withID: seeded.bookID)!.book
        let chapter = store.book(withID: seeded.bookID)!.chapters[0]
        let session = PlaybackSession(
            book: staleBook, chapters: [chapter], chapter: chapter,
            position: 0, duration: chapter.duration, isPlaying: false
        )
        XCTAssertFalse(NowPlayingView.resolveFavorite(storeBook: store.book(withID: seeded.bookID), session: session))

        // Favoriting through the store must flip the derived value even though the
        // session snapshot is stale.
        await store.setFavorite(true, for: seeded.bookID)
        XCTAssertEqual(store.book(withID: seeded.bookID)?.book.isFavorite, true)
        XCTAssertTrue(
            NowPlayingView.resolveFavorite(storeBook: store.book(withID: seeded.bookID), session: session),
            "Derivation must prefer the live store value over the stale session snapshot"
        )

        // Unfavoriting flips it back.
        await store.setFavorite(false, for: seeded.bookID)
        XCTAssertFalse(NowPlayingView.resolveFavorite(storeBook: store.book(withID: seeded.bookID), session: session))
    }

    func testFallsBackToSessionWhenBookMissingFromStore() {
        let source = UUID()
        let book = Book(title: "Detached", authors: ["A"], sourceID: source, isFavorite: true)
        let chapter = Chapter(bookID: book.id, title: "Ch", index: 0)
        let session = PlaybackSession(
            book: book, chapters: [chapter], chapter: chapter,
            position: 0, duration: nil, isPlaying: false
        )
        XCTAssertTrue(NowPlayingView.resolveFavorite(storeBook: nil, session: session))
    }

    private func seedBook(
        in database: AppDatabase,
        title: String
    ) async throws -> (bookID: UUID, chapterID: UUID) {
        let sourceID = UUID(), bookID = UUID(), chapterID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("\(title) Source"), .null, .double(now)]
        )
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string(title), .string(ModelMapping.authorsJSON(["Author"])), .null,
            .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false)
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString), .string(bookID.uuidString), .string("Chapter 1"), .string("Chapter 1"),
            .int(0), .double(120), .null, .string(URL(fileURLWithPath: "/tmp/\(chapterID.uuidString).mp3").absoluteString)
        ])
        return (bookID, chapterID)
    }
}
