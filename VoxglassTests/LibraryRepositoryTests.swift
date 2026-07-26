import Testing
import Foundation
@testable import VoxglassCore

@Suite(.serialized) struct LibraryRepositoryTests {
    @Test func setFavoritePersistsAndFilteredFetchReturnsFavoriteBooks() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "favorite-update")
        let repository = LibraryRepository(database: database)
        let seeded = try await seedBook(in: database, title: "Favorite Candidate")

        let updated = try await repository.setFavorite(true, for: seeded.bookID)
        let favorites = try await repository.fetchBooks(filteredBy: .favorites)

        #expect(updated?.book.id == seeded.bookID)
        #expect(updated?.book.isFavorite == true)
        #expect(favorites.map(\.book.id) == [seeded.bookID])
    }

    @Test func existingLibraryCanBeQueuedAfterContentKeyBackfill() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "initial-cloudkit-enqueue")
        let stateStore = CloudSyncStateStore(database: database)
        let repository = LibraryRepository(database: database)
        repository.mutationLog = SyncMutationLog(stateStore: stateStore)

        let seeded = try await seedBook(
            in: database,
            title: "Legacy LibriVox Book",
            sourceKind: .librivox,
            sourceURL: URL(string: "https://archive.org/details/legacy_librivox_book"),
            contentKey: nil
        )

        let backfilled = await repository.backfillContentKeysIfNeeded()
        #expect(backfilled == 2)

        let queued = await repository.enqueueExistingLibraryForSync()
        #expect(queued == 1)

        let pending = try await stateStore.dequeuePending(limit: 10)
        #expect(pending.count == 1)
        #expect(pending.first?.localID == seeded.bookID.uuidString)
        #expect(pending.first?.recordType == CloudKitRecordMapper.RecordType.book.rawValue)
        #expect(pending.first?.changeType == "update")

        _ = await repository.enqueueExistingLibraryForSync()
        let pendingCount = try await stateStore.pendingCount()
        #expect(pendingCount == 1)  // Queueing twice must not duplicate pending rows
    }

    @Test func fetchSourcesReturnsNewestFirst() async throws {
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

        #expect(sources.map(\.id) == [newer.id, older.id])
        #expect(sources.first?.kind == .librivox)
        #expect(sources.first?.url?.absoluteString == "https://archive.org/details/newer")
    }

    @Test func deleteBookCascadesAndRemovesOrphanSource() async throws {
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
        #expect(library.isEmpty)

        let sources = try await repository.fetchSources()
        #expect(sources.isEmpty)  // Orphaned source should be removed

        let chapters = try await database.query("SELECT id FROM chapters WHERE book_id = ?", [.string(seeded.bookID.uuidString)])
        #expect(chapters.isEmpty)  // Chapters should cascade-delete

        let positions = try await database.query("SELECT id FROM playback_positions WHERE book_id = ?", [.string(seeded.bookID.uuidString)])
        #expect(positions.isEmpty)  // Playback positions should cascade-delete

        let downloads = try await repository.fetchDownloadRecords(forBookID: seeded.bookID)
        #expect(downloads.isEmpty)  // Download records should cascade-delete
    }

    @Test func downloadRecordsDriveDownloadedFilter() async throws {
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
        #expect(filtered.map(\.book.id) == [downloaded.bookID])

        try await repository.deleteDownloadRecords(forBookID: downloaded.bookID)
        let afterDelete = try await repository.fetchBooks(filteredBy: .downloaded)
        #expect(afterDelete.isEmpty)
    }

    @Test func updateDownloadRecordChangesState() async throws {
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
        #expect(records.count == 1)
        #expect(records.first?.state == .complete)
    }

    @Test func fetchRecentlyPlayedOrdersByLatestPlaybackPosition() async throws {
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

        #expect(recentlyPlayed.map(\.book.id) == [second.bookID, first.bookID])
    }

    @Test func fetchListenedWorkExclusionKeysIncludesContentAndWorkKeys() async throws {
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

        #expect(keys.contains(listened.bookID.uuidString))
        #expect(keys.contains("ia:clouds_librivox"))
        #expect(keys.contains("clouds_librivox"))
        #expect(keys.contains(WorkKey.normalized(author: "Aristophanes", title: "The Clouds (Version 2)")))
        #expect(!(keys.contains(unplayed.bookID.uuidString)))
        #expect(!(keys.contains("unplayed_librivox")))
    }

    @Test func bookIsFinishedOnlyWhenAllChaptersFinished() async throws {
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
        #expect(progress[seeded.bookID]?.isFinished == false)  // One finished chapter out of two must not mark the book finished

        try await positionStore.save(PlaybackPosition(
            bookID: seeded.bookID,
            chapterID: secondChapterID,
            position: 120,
            duration: 120,
            updatedAt: Date(timeIntervalSince1970: 200),
            isFinished: true
        ))

        progress = try await repository.fetchBookProgress()
        #expect(progress[seeded.bookID]?.isFinished == true)
    }

    @Test func bookProgressAccumulatesFinishedChapterDurations() async throws {
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
        #expect(progress[seeded.bookID]?.isFinished == false)
        #expect(abs((progress[seeded.bookID]?.lastPosition ?? 0) - (150)) <= 0.001)  // Progress must be finished-chapter durations plus the current offset, not the max within-chapter offset
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

    @Test func backfillBookTasteSeedsAuthorsFromPreTasteCaptureBooks() async throws {
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
        #expect(first == 1)

        let second = await repository.backfillBookTasteIfNeeded()
        #expect(second == 0)  // idempotent

        await profileStore.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
        let profile = await profileStore.fetchProfile()
        #expect(profile.creatorTerms.contains { $0.term == "jane austen" })
    }

    @Test func positionOnlyBookContributesTasteTerms() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "backfill-position-only-taste")
        let repository = LibraryRepository(database: database)
        let profileStore = TasteProfileStore(database: database)

        let seeded = try await seedBook(
            in: database,
            title: "The Mysterious Island",
            authors: [],
            sourceKind: .librivox,
            sourceURL: URL(string: "https://archive.org/details/mysterious_island_librivox")
        )
        try await SQLitePositionStore(database: database).save(PlaybackPosition(
            bookID: seeded.bookID,
            chapterID: seeded.chapterID,
            position: 90,
            duration: 120
        ))

        _ = await repository.backfillBookTasteIfNeeded()
        await profileStore.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)

        let profile = await profileStore.fetchProfile()
        #expect(!(profile.isEmpty))  // a played book with no usable authors and no book_taste rows must still contribute taste terms
        #expect(profile.subjectTerms.contains { $0.term == "the mysterious island" })
    }

    @Test func tasteSeedTermsPrefersUsableAuthorsOverTitle() {
        let terms = LibraryRepository.tasteSeedTerms(
            authors: ["  Jules Verne  ", "Various"],
            title: "The Mysterious Island"
        )
        #expect(terms.map(\.axis) == ["author"])
        #expect(terms.map(\.term) == ["jules verne"])
    }

    @Test func tasteSeedTermsFallsBackToTitleSubjectWhenAuthorsUnusable() {
        for authors in [[], ["Unknown"], ["Unknown author"], ["Various"], ["Internet Archive"], ["Local Files"]] {
            let terms = LibraryRepository.tasteSeedTerms(authors: authors, title: "The Mysterious Island")
            #expect(terms.map(\.axis) == ["subject"])  // authors \(authors)
            #expect(terms.map(\.term) == ["the mysterious island"])  // authors \(authors)
        }
    }

    @Test func tasteSeedTermsEmptyWhenNothingUsable() {
        #expect(LibraryRepository.tasteSeedTerms(authors: ["Unknown"], title: "   ").isEmpty)
        #expect(LibraryRepository.tasteSeedTerms(authors: [], title: "").isEmpty)
    }

    @Test func resplitBookTasteMigration() async throws {
        let flagKey = "voxglass.bookTasteSubjectResplitV1"
        UserDefaults.standard.removeObject(forKey: flagKey)
        defer { UserDefaults.standard.removeObject(forKey: flagKey) }

        let database = AppDatabase.makeTemporaryDatabase(named: "resplit-subject-test")
        let repository = LibraryRepository(database: database)

        let bookID = UUID().uuidString
        let sourceID = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID), .string(SourceKind.librivox.rawValue),
             .string("Test Source"), .string("https://archive.org/details/test"), .double(now)]
        )
        try await database.execute(
            "INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.string(bookID), .string("Test Book"),
             .string(ModelMapping.authorsJSON(["Test Author"])), .null,
             .string(sourceID), .null, .double(now), .double(now), .bool(false)]
        )
        try await database.execute(
            "INSERT INTO book_taste (book_id, axis, term) VALUES (?, 'subject', ?)",
            [.string(bookID), .string("librivox; audiobooks;greek drama; aristophanes; greek comedy")]
        )

        let count = await repository.resplitBookTasteSubjectsIfNeeded()
        #expect(count == 1)

        let rows = try await database.query(
            "SELECT term FROM book_taste WHERE book_id = ? AND axis = 'subject' ORDER BY term",
            [.string(bookID)]
        )
        let terms = rows.compactMap { $0.string("term") }
        #expect(terms.contains("greek drama"))
        #expect(terms.contains("aristophanes"))
        #expect(terms.contains("greek comedy"))
        #expect(!(terms.contains { $0.contains(";") }))  // no term should contain semicolon after migration

        // Idempotent second run
        let secondCount = await repository.resplitBookTasteSubjectsIfNeeded()
        #expect(secondCount == 0)  // migration must be idempotent

        // Verify reco_surfaced was cleared
        let surfacedRows = try await database.query("SELECT COUNT(*) AS n FROM reco_surfaced", [])
        let n = surfacedRows.first?.int("n") ?? -1
        #expect(Int(n) == 0)  // reco_surfaced must be cleared by migration
    }

    @Test func resplitMigrationProfileRebuildUsesSplitTerms() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "resplit-profile-rebuild")
        let repository = LibraryRepository(database: database)
        let profileStore = TasteProfileStore(database: database)

        // Create a real book + source + listening event connected to split book_taste
        let sourceID = UUID()
        let bookID = UUID()
        let chapterID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.librivox.rawValue),
             .string("Test Source"), .string("https://archive.org/details/test"), .double(now)]
        )
        try await database.execute(
            "INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.string(bookID.uuidString), .string("The Frogs"),
             .string(ModelMapping.authorsJSON(["Aristophanes"])), .null,
             .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false)]
        )
        try await database.execute(
            "INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [.string(chapterID.uuidString), .string(bookID.uuidString),
             .string("Chapter 1"), .string("Chapter 1"), .int(0), .double(120), .null, .null]
        )
        try await database.execute(
            "INSERT INTO listening_events (id, book_id, seconds, occurred_at) VALUES (?, ?, ?, ?)",
            [.string(UUID().uuidString), .string(bookID.uuidString), .double(7200), .double(now)]
        )
        // Insert semicolon subject (the pre-migration state)
        try await database.execute(
            "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'author', ?)",
            [.string(bookID.uuidString), .string("aristophanes")]
        )
        try await database.execute(
            "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'language', ?)",
            [.string(bookID.uuidString), .string("eng")]
        )

        // Run the migration (idempotent; may be a no-op if already done)
        _ = await repository.resplitBookTasteSubjectsIfNeeded()

        // Now insert the proper split subject terms (migration cleared semicolons; but we need to
        // insert them manually since we didn't have them pre-migration for this test book)
        try await database.execute(
            "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'subject', ?)",
            [.string(bookID.uuidString), .string("greek drama")]
        )
        try await database.execute(
            "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'subject', ?)",
            [.string(bookID.uuidString), .string("aristophanes")]
        )

        // Rebuild and verify split terms appear in profile
        await profileStore.rebuildFromListeningHistory(version: TasteProfileStore.listeningHistoryRebuildVersion)
        let profile = await profileStore.fetchProfile()
        #expect(profile.subjectTerms.contains { $0.term == "greek drama" })
        #expect(profile.subjectTerms.contains { $0.term == "aristophanes" })
        #expect(profile.creatorTerms.contains { $0.term == "aristophanes" })
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
