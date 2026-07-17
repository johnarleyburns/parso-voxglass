import XCTest
@testable import VoxglassCore

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

    func testDeleteBookCascadesAndRemovesOrphanSource() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "delete-cascade")
        let repository = LibraryRepository(database: database)
        let seeded = try await seedBook(in: database, title: "Doomed Book")
        let positionStore = SQLitePositionStore(database: database)

        try await positionStore.save(PlaybackPosition(
            bookID: seeded.bookID,
            chapterID: seeded.chapterID,
            position: 5,
            duration: 120
        ))
        try await repository.replaceDownloadRecords([
            DownloadRecord(
                id: UUID(),
                bookID: seeded.bookID,
                chapterID: seeded.chapterID,
                state: .complete,
                localURL: nil,
                bytesDownloaded: 10,
                bytesExpected: 10,
                updatedAt: Date()
            )
        ], forBookID: seeded.bookID)

        try await repository.deleteBook(seeded.bookID)

        let library = try await repository.fetchLibrary()
        XCTAssertTrue(library.isEmpty)

        let sources = try await repository.fetchSources()
        XCTAssertTrue(sources.isEmpty, "Orphaned source should be removed")

        let chapters = try await database.query("SELECT id FROM chapters WHERE book_id = ?", [.string(seeded.bookID.uuidString)])
        XCTAssertTrue(chapters.isEmpty, "Chapters should cascade-delete")

        let positions = try await database.query("SELECT id FROM playback_positions WHERE book_id = ?", [.string(seeded.bookID.uuidString)])
        XCTAssertTrue(positions.isEmpty, "Playback positions should cascade-delete")

        let downloads = try await repository.fetchDownloadRecords(forBookID: seeded.bookID)
        XCTAssertTrue(downloads.isEmpty, "Download records should cascade-delete")
    }

    func testDownloadRecordsDriveDownloadedFilter() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "downloaded-filter")
        let repository = LibraryRepository(database: database)
        let downloaded = try await seedBook(in: database, title: "Cached Book")
        _ = try await seedBook(in: database, title: "Streamed Book")

        try await repository.replaceDownloadRecords([
            DownloadRecord(
                id: UUID(),
                bookID: downloaded.bookID,
                chapterID: downloaded.chapterID,
                state: .complete,
                localURL: nil,
                bytesDownloaded: 100,
                bytesExpected: 100,
                updatedAt: Date()
            )
        ], forBookID: downloaded.bookID)

        let filtered = try await repository.fetchBooks(filteredBy: .downloaded)
        XCTAssertEqual(filtered.map(\.book.id), [downloaded.bookID])

        try await repository.deleteDownloadRecords(forBookID: downloaded.bookID)
        let afterDelete = try await repository.fetchBooks(filteredBy: .downloaded)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testUpdateDownloadRecordChangesState() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "download-update")
        let repository = LibraryRepository(database: database)
        let seeded = try await seedBook(in: database, title: "Progressing Book")

        try await repository.replaceDownloadRecords([
            DownloadRecord(
                id: UUID(),
                bookID: seeded.bookID,
                chapterID: seeded.chapterID,
                state: .downloading,
                localURL: nil,
                bytesDownloaded: 0,
                bytesExpected: nil,
                updatedAt: Date()
            )
        ], forBookID: seeded.bookID)

        try await repository.updateDownloadRecord(
            bookID: seeded.bookID,
            chapterID: seeded.chapterID,
            state: .complete
        )

        let records = try await repository.fetchDownloadRecords(forBookID: seeded.bookID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .complete)
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

    func testFetchListenedWorkExclusionKeysIncludesContentAndWorkKeys() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "listened-work-keys")
        let repository = LibraryRepository(database: database)
        let listened = try await seedBook(
            in: database,
            title: "The Clouds (Version 2)",
            authors: ["Aristophanes"],
            sourceKind: .librivox,
            sourceURL: URL(string: "https://archive.org/details/clouds_librivox"),
            contentKey: "ia:clouds_librivox"
        )
        let unplayed = try await seedBook(
            in: database,
            title: "Unplayed Book",
            authors: ["Aristophanes"],
            sourceKind: .librivox,
            sourceURL: URL(string: "https://archive.org/details/unplayed_librivox"),
            contentKey: "ia:unplayed_librivox"
        )
        let positionStore = SQLitePositionStore(database: database)

        try await positionStore.save(PlaybackPosition(
            bookID: listened.bookID,
            chapterID: listened.chapterID,
            position: 12,
            duration: 120
        ))

        let keys = try await repository.fetchListenedWorkExclusionKeys()

        XCTAssertTrue(keys.contains(listened.bookID.uuidString))
        XCTAssertTrue(keys.contains("ia:clouds_librivox"))
        XCTAssertTrue(keys.contains("clouds_librivox"))
        XCTAssertTrue(keys.contains(WorkKey.normalized(author: "Aristophanes", title: "The Clouds (Version 2)")))
        XCTAssertFalse(keys.contains(unplayed.bookID.uuidString))
        XCTAssertFalse(keys.contains("unplayed_librivox"))
    }

    func testBookIsFinishedOnlyWhenAllChaptersFinished() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "progress-finished")
        let repository = LibraryRepository(database: database)
        let seeded = try await seedBook(in: database, title: "Two Chapter Book")
        let secondChapterID = try await seedExtraChapter(in: database, bookID: seeded.bookID, index: 1)
        let positionStore = SQLitePositionStore(database: database)

        try await positionStore.save(PlaybackPosition(
            bookID: seeded.bookID,
            chapterID: seeded.chapterID,
            position: 120,
            duration: 120,
            updatedAt: Date(timeIntervalSince1970: 100),
            isFinished: true
        ))

        var progress = try await repository.fetchBookProgress()
        XCTAssertEqual(
            progress[seeded.bookID]?.isFinished, false,
            "One finished chapter out of two must not mark the book finished"
        )

        try await positionStore.save(PlaybackPosition(
            bookID: seeded.bookID,
            chapterID: secondChapterID,
            position: 120,
            duration: 120,
            updatedAt: Date(timeIntervalSince1970: 200),
            isFinished: true
        ))

        progress = try await repository.fetchBookProgress()
        XCTAssertEqual(progress[seeded.bookID]?.isFinished, true)
    }

    func testBookProgressAccumulatesFinishedChapterDurations() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "progress-cumulative")
        let repository = LibraryRepository(database: database)
        let seeded = try await seedBook(in: database, title: "Cumulative Book")
        let secondChapterID = try await seedExtraChapter(in: database, bookID: seeded.bookID, index: 1)
        let positionStore = SQLitePositionStore(database: database)

        try await positionStore.save(PlaybackPosition(
            bookID: seeded.bookID,
            chapterID: seeded.chapterID,
            position: 120,
            duration: 120,
            updatedAt: Date(timeIntervalSince1970: 100),
            isFinished: true
        ))
        try await positionStore.save(PlaybackPosition(
            bookID: seeded.bookID,
            chapterID: secondChapterID,
            position: 30,
            duration: 120,
            updatedAt: Date(timeIntervalSince1970: 200),
            isFinished: false
        ))

        let progress = try await repository.fetchBookProgress()
        XCTAssertEqual(progress[seeded.bookID]?.isFinished, false)
        XCTAssertEqual(
            progress[seeded.bookID]?.lastPosition ?? 0, 150, accuracy: 0.001,
            "Progress must be finished-chapter durations plus the current offset, not the max within-chapter offset"
        )
    }

    private func seedExtraChapter(
        in database: AppDatabase,
        bookID: UUID,
        index: Int
    ) async throws -> UUID {
        let chapterID = UUID()
        try await database.execute("""
        INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(chapterID.uuidString),
            .string(bookID.uuidString),
            .string("Chapter \(index + 1)"),
            .string("Chapter \(index + 1)"),
            .int(Int64(index)),
            .double(120),
            .null,
            .string(URL(fileURLWithPath: "/tmp/\(chapterID.uuidString).mp3").absoluteString)
        ])
        return chapterID
    }

    private func seedBook(
        in database: AppDatabase,
        title: String,
        authors: [String] = ["Test Author"],
        isFavorite: Bool = false,
        sourceKind: SourceKind = .localFiles,
        sourceURL: URL? = nil,
        contentKey: String? = nil
    ) async throws -> (sourceID: UUID, bookID: UUID, chapterID: UUID) {
        let source = try await seedSource(
            in: database,
            title: "\(title) Source",
            kind: sourceKind,
            url: sourceURL,
            createdAt: Date()
        )
        let bookID = UUID()
        let chapterID = UUID()
        let now = Date().timeIntervalSince1970

        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string(title),
            .string(ModelMapping.authorsJSON(authors)),
            .string("Seed summary"),
            .string(source.id.uuidString),
            .null,
            .double(now),
            .double(now),
            .bool(isFavorite),
            contentKey.map { .string($0) } ?? .null
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

    func testBackfillBookTasteSeedsAuthorsFromPreTasteCaptureBooks() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "backfill-taste")
        let repository = LibraryRepository(database: database)
        let profileStore = TasteProfileStore(database: database)

        // Seed a book without book_taste rows (pre-2026-07-11 state)
        let sourceID = UUID()
        let bookID = UUID()
        let chapterID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(sourceID.uuidString),
            .string(SourceKind.librivox.rawValue),
            .string("Test Book"),
            .string("https://archive.org/details/test-book"),
            .double(now)
        ])
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string("Test Book"),
            .string(ModelMapping.authorsJSON(["Jane Austen"])),
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
            .double(120),
            .null,
            .null
        ])
        try await database.execute("""
        INSERT INTO listening_events (id, book_id, seconds, occurred_at)
        VALUES (?, ?, ?, ?)
        """, [
            .string(UUID().uuidString),
            .string(bookID.uuidString),
            .double(3600),
            .double(now)
        ])

        let first = await repository.backfillBookTasteIfNeeded()
        XCTAssertEqual(first, 1)

        let second = await repository.backfillBookTasteIfNeeded()
        XCTAssertEqual(second, 0, "idempotent")

        await profileStore.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
        let profile = await profileStore.fetchProfile()
        XCTAssertTrue(profile.creatorTerms.contains { $0.term == "jane austen" })
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
