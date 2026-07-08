import XCTest
@testable import Voxglass

final class LibraryRepositoryTests: XCTestCase {
    func testSetFavoritePersistsAndFilteredFetchReturnsFavoriteBooks() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "favorite-update")
        let repository = LibraryRepository(database: database)
        let seeded = try await seedBook(in: database, title: "Favorite Candidate")

        let updated = try await repository.setFavorite(true, for: seeded.bookID)
        let favorites = try await repository.fetchBooks(filteredBy: .favorites)

        XCTAssertEqual(updated?.book.id, seeded.bookID)
        XCTAssertEqual(updated?.book.isFavorite, true)
        XCTAssertEqual(favorites.map(\.book.id), [seeded.bookID])
    }

    func testFetchSourcesReturnsNewestFirst() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "source-fetch")
        let repository = LibraryRepository(database: database)

        let older = try await seedSource(
            in: database,
            title: "Older Source",
            kind: .localFiles,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newer = try await seedSource(
            in: database,
            title: "Newer Source",
            kind: .librivox,
            url: URL(string: "https://archive.org/details/newer"),
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let sources = try await repository.fetchSources()

        XCTAssertEqual(sources.map(\.id), [newer.id, older.id])
        XCTAssertEqual(sources.first?.kind, .librivox)
        XCTAssertEqual(sources.first?.url?.absoluteString, "https://archive.org/details/newer")
    }

    func testFetchRecentlyPlayedOrdersByLatestPlaybackPosition() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "recently-played")
        let repository = LibraryRepository(database: database)
        let first = try await seedBook(in: database, title: "First Book")
        let second = try await seedBook(in: database, title: "Second Book")
        let positionStore = SQLitePositionStore(database: database)

        try await positionStore.save(PlaybackPosition(
            bookID: first.bookID,
            chapterID: first.chapterID,
            position: 10,
            duration: 120,
            updatedAt: Date(timeIntervalSince1970: 100)
        ))
        try await positionStore.save(PlaybackPosition(
            bookID: second.bookID,
            chapterID: second.chapterID,
            position: 20,
            duration: 120,
            updatedAt: Date(timeIntervalSince1970: 200)
        ))

        let recentlyPlayed = try await repository.fetchRecentlyPlayed()

        XCTAssertEqual(recentlyPlayed.map(\.book.id), [second.bookID, first.bookID])
    }

    private func seedBook(
        in database: AppDatabase,
        title: String,
        authors: [String] = ["Test Author"],
        isFavorite: Bool = false
    ) async throws -> (sourceID: UUID, bookID: UUID, chapterID: UUID) {
        let source = try await seedSource(
            in: database,
            title: "\(title) Source",
            kind: .localFiles,
            createdAt: Date()
        )
        let bookID = UUID()
        let chapterID = UUID()
        let now = Date().timeIntervalSince1970

        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string(title),
            .string(ModelMapping.authorsJSON(authors)),
            .string("Seed summary"),
            .string(source.id.uuidString),
            .null,
            .double(now),
            .double(now),
            .bool(isFavorite)
        ])
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString),
            .string(bookID.uuidString),
            .string("Chapter 1"),
            .string("Chapter 1"),
            .int(0),
            .double(120),
            .null,
            .string(URL(fileURLWithPath: "/tmp/\(chapterID.uuidString).mp3").absoluteString)
        ])

        return (source.id, bookID, chapterID)
    }

    @discardableResult
    private func seedSource(
        in database: AppDatabase,
        title: String,
        kind: SourceKind,
        url: URL? = nil,
        createdAt: Date
    ) async throws -> Source {
        let source = Source(kind: kind, title: title, url: url, createdAt: createdAt)
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(source.id.uuidString),
            .string(source.kind.rawValue),
            .string(source.title),
            url.map { .string($0.absoluteString) } ?? .null,
            .double(source.createdAt.timeIntervalSince1970)
        ])
        return source
    }
}
