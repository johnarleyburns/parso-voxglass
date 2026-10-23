import Testing
import Foundation
@testable import VoxglassCore

@Suite struct RecordingIdentityRepositoryTests {
    private let blackstone = "commentaries_blackstone_0810_librivox"

    private func metadata(callNumber: String?) -> InternetArchiveMetadata {
        InternetArchiveMetadata(
            metadata: InternetArchiveItemMetadata(
                identifier: blackstone,
                title: "Commentaries on the Laws of England (1765)",
                creators: ["William Blackstone"],
                mediatype: "audio",
                collections: ["librivoxaudio"],
                language: "eng",
                callNumber: callNumber
            ),
            files: [
                InternetArchiveFile(
                    name: "01 Chapter.mp3", source: "original", format: "VBR MP3",
                    title: "Chapter 1", length: "100", track: "1", size: "1000"
                )
            ],
            server: "ia.example.org",
            dir: "/1/items/\(blackstone)"
        )
    }

    private func identities(_ database: AppDatabase) async throws -> [String] {
        try await database.query("SELECT scheme, value FROM book_recording_identities ORDER BY scheme, value")
            .map { "\($0.string("scheme") ?? "")/\($0.string("value") ?? "")" }
    }

    private func seedBook(
        _ database: AppDatabase, contentKey: String?, sourceURL: String?, chapterURLs: [String]
    ) async throws -> UUID {
        let sourceID = UUID(), bookID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, 'librivox', 'S', ?, ?)",
            [.string(sourceID.uuidString), sourceURL.map { .string($0) } ?? .null, .double(now)]
        )
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, source_id, content_key, created_at, updated_at, is_favorite)
        VALUES (?, 'Legacy', '[]', ?, ?, ?, ?, 0)
        """, [.string(bookID.uuidString), .string(sourceID.uuidString),
              contentKey.map { .string($0) } ?? .null, .double(now), .double(now)])
        var firstChapter: UUID?
        for (index, url) in chapterURLs.enumerated() {
            let id = UUID()
            firstChapter = firstChapter ?? id
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url)
            VALUES (?, ?, ?, ?, ?, 60, ?)
            """, [.string(id.uuidString), .string(bookID.uuidString), .string("C\(index)"),
                  .string("C\(index)"), .int(Int64(index)), .string(url)])
        }
        if let chapter = firstChapter {
            try await database.execute("""
            INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
            VALUES (?, ?, ?, 42, 60, ?, 0)
            """, [.string(UUID().uuidString), .string(bookID.uuidString), .string(chapter.uuidString), .double(now)])
            try await database.execute(
                "INSERT INTO bookmarks (id, book_id, chapter_id, position_seconds, note, created_at) VALUES (?, ?, ?, 10, NULL, ?)",
                [.string(UUID().uuidString), .string(bookID.uuidString), .string(chapter.uuidString), .double(now)]
            )
        }
        return bookID
    }

    @Test func freshImportWritesInternetArchiveAndLibriVoxAliases() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "identity-fresh")
        let repository = LibraryRepository(database: database)
        let imported = try await repository.importInternetArchiveItem(metadata(callNumber: "1735"), sourceKind: .internetArchive)
        #expect(try await identities(database) == ["internet-archive/\(blackstone)", "librivox/1735"])
        let found = try await repository.bookWithChapters(identityScheme: "librivox", value: "1735")
        #expect(found?.book.id == imported.book.id)
    }

    @Test func normalizationAcceptsOnlyExactNumericIDs() {
        let normalize = LibraryRepository.RecordingIdentity.normalizedLibriVoxID
        #expect(normalize(" 1735\n") == "1735")
        #expect(normalize("01735") == "1735")
        for bad in [nil, "", "  ", "-1735", "+1735", "17.35", "1735a", "abc", "99999999999999999999"] {
            #expect(normalize(bad) == nil)
        }
    }

    @Test func migrationCreatesTableIndexAndCascadesAndIsRepeatable() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "identity-migration")
        try await database.prepare()
        try await database.prepare()
        try await database.migrate() // already fully migrated: no-op
        let applied = try await database.query("SELECT id FROM schema_migrations WHERE id = 15")
        #expect(applied.count == 1)
        let index = try await database.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'book_recording_identities_lookup'")
        #expect(index.count == 1)

        let bookID = try await seedBook(database, contentKey: nil, sourceURL: nil, chapterURLs: [])
        try await database.execute(
            "INSERT INTO book_recording_identities (book_id, scheme, value, created_at) VALUES (?, 'librivox', '1', 0)",
            [.string(bookID.uuidString)])
        try await database.execute("DELETE FROM books WHERE id = ?", [.string(bookID.uuidString)])
        #expect(try await identities(database).isEmpty)
    }

    @Test func backfillCollisionNeverMergesOrAltersListenerData() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "identity-collision")
        let repository = LibraryRepository(database: database)
        let url = "https://archive.org/download/\(blackstone)/01.mp3"
        let first = try await seedBook(database, contentKey: "ia:\(blackstone)", sourceURL: nil, chapterURLs: [url])
        let second = try await seedBook(database, contentKey: nil, sourceURL: nil, chapterURLs: [url])

        _ = await repository.backfillRecordingIdentitiesIfNeeded()
        #expect(repository.recordingIdentityCollisionCount == 1)
        #expect(try await identities(database) == ["internet-archive/\(blackstone)"])
        let owner = try await database.query("SELECT book_id FROM book_recording_identities")
        #expect(owner.first?.string("book_id") == first.uuidString)

        // Idempotent; both books and their listener data remain.
        _ = await repository.backfillRecordingIdentitiesIfNeeded()
        #expect(try await identities(database).count == 1)
        for id in [first, second] {
            let books = try await database.query("SELECT id FROM books WHERE id = ?", [.string(id.uuidString)])
            let positions = try await database.query("SELECT id FROM playback_positions WHERE book_id = ?", [.string(id.uuidString)])
            let bookmarks = try await database.query("SELECT id FROM bookmarks WHERE book_id = ?", [.string(id.uuidString)])
            #expect(books.count == 1)
            #expect(positions.count == 1)
            #expect(bookmarks.count == 1)
        }
    }

    @Test func backfillNeverInventsLibriVoxAliasFromLegacyLibriVoxURLs() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "identity-no-heuristic")
        let repository = LibraryRepository(database: database)
        _ = try await seedBook(
            database, contentKey: nil, sourceURL: "https://librivox.org/commentaries-on-the-laws-of-england-1765",
            chapterURLs: ["https://librivox.org/uploads/blackstone/commentaries_01.mp3"])
        _ = try await seedBook(
            database, contentKey: nil, sourceURL: nil,
            chapterURLs: ["https://archive.org/download/a_book/01.mp3", "https://archive.org/download/b_book/02.mp3"])
        _ = await repository.backfillRecordingIdentitiesIfNeeded()
        #expect(try await identities(database).isEmpty)
    }
}
