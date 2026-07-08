import XCTest
@testable import Voxglass

final class PositionStoreTests: XCTestCase {
    func testPositionRoundTripsThroughSQLite() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "position-round-trip")
        let ids = try await seedBook(in: database)
        let store = SQLitePositionStore(database: database)
        let saved = PlaybackPosition(
            bookID: ids.bookID,
            chapterID: ids.chapterID,
            position: 42.5,
            duration: 300,
            updatedAt: Date(timeIntervalSince1970: 123),
            isFinished: false
        )

        try await store.save(saved)
        let fetchedOptional = try await store.position(for: ids.bookID, chapterID: ids.chapterID)
        let fetched = try XCTUnwrap(fetchedOptional)

        XCTAssertEqual(fetched.bookID, ids.bookID)
        XCTAssertEqual(fetched.chapterID, ids.chapterID)
        XCTAssertEqual(fetched.position, 42.5, accuracy: 0.001)
        XCTAssertEqual(fetched.duration ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(fetched.isFinished, false)
    }

    func testLatestPositionReturnsMostRecentlyUpdatedRecord() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "latest-position")
        let first = try await seedBook(in: database, title: "First")
        let second = try await seedBook(in: database, title: "Second")
        let store = SQLitePositionStore(database: database)

        try await store.save(PlaybackPosition(
            bookID: first.bookID,
            chapterID: first.chapterID,
            position: 5,
            duration: 10,
            updatedAt: Date(timeIntervalSince1970: 100)
        ))
        try await store.save(PlaybackPosition(
            bookID: second.bookID,
            chapterID: second.chapterID,
            position: 7,
            duration: 10,
            updatedAt: Date(timeIntervalSince1970: 200)
        ))

        let latestOptional = try await store.latestPosition()
        let latest = try XCTUnwrap(latestOptional)

        XCTAssertEqual(latest.bookID, second.bookID)
        XCTAssertEqual(latest.position, 7, accuracy: 0.001)
    }

    private func seedBook(
        in database: AppDatabase,
        title: String = "Seed Book"
    ) async throws -> (sourceID: UUID, bookID: UUID, chapterID: UUID) {
        let sourceID = UUID()
        let bookID = UUID()
        let chapterID = UUID()
        let now = Date().timeIntervalSince1970

        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(sourceID.uuidString),
            .string(SourceKind.localFiles.rawValue),
            .string("Local Files"),
            .null,
            .double(now)
        ])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string(title),
            .string("[]"),
            .null,
            .string(sourceID.uuidString),
            .null,
            .double(now),
            .double(now),
            .bool(false)
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
            .double(300),
            .null,
            .string(URL(fileURLWithPath: "/tmp/chapter.mp3").absoluteString)
        ])

        return (sourceID, bookID, chapterID)
    }
}
