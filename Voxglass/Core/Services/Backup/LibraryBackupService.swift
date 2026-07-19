import Foundation
import UniformTypeIdentifiers

public struct BackupPayload: Codable, Equatable {
    public let version: Int
    public let exportDate: Date
    public let books: [BookPayload]
    public let positions: [PlaybackPosition]
    public let bookmarks: [Bookmark]
    public let playlists: [PlaylistPayload]
    public let tasteTerms: [TasteTermPayload]

    public struct BookPayload: Codable, Equatable {
        var book: Book
        var chapters: [Chapter]
        var source: Source?
    }

    public struct PlaylistPayload: Codable, Equatable {
        var playlist: Playlist
        var bookIDs: [UUID]
    }

    public struct TasteTermPayload: Codable, Equatable {
        var axis: String
        var term: String
        var weight: Double
    }

    public static let utType = UTType("guru.parso.voxglass.backup") ?? .json
    public static let currentVersion = 1
}

@MainActor
public final class LibraryBackupService: ObservableObject {
    @Published public var isExporting = false
    @Published public var isImporting = false
    @Published public var exportError: String?
    @Published public var importError: String?

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func exportPayload() async -> BackupPayload? {
        do {
            try await database.prepare()

            let books = try await fetchBooks()
            let positions = try await fetchPositions()
            let bookmarks = try await fetchBookmarks()
            let playlists = try await fetchPlaylists()
            let tasteTerms = try await fetchTasteTerms()

            return BackupPayload(
                version: BackupPayload.currentVersion,
                exportDate: Date(),
                books: books,
                positions: positions,
                bookmarks: bookmarks,
                playlists: playlists,
                tasteTerms: tasteTerms
            )
        } catch {
            exportError = error.localizedDescription
            return nil
        }
    }

    public func exportToFile() async -> URL? {
        guard let payload = await exportPayload() else { return nil }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)

            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "Voxglass Backup \(DateFormatter.voxglassBackup.string(from: payload.exportDate)).json"
            let url = tempDir.appendingPathComponent(fileName)
            try data.write(to: url)
            return url
        } catch {
            exportError = error.localizedDescription
            return nil
        }
    }

    public func importFromFile(_ url: URL) async -> Int {
        guard url.startAccessingSecurityScopedResource() else {
            importError = "Could not access the backup file."
            return 0
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let payload = try decoder.decode(BackupPayload.self, from: data)

            guard payload.version <= BackupPayload.currentVersion else {
                importError = "Backup file was created by a newer version of Voxglass."
                return 0
            }

            return await importPayload(payload)
        } catch {
            importError = error.localizedDescription
            return 0
        }
    }

    public func importPayload(_ payload: BackupPayload) async -> Int {
        var importedCount = 0

        do {
            try await database.prepare()

            for bp in payload.books {
                guard try await !bookExists(bp.book) else { continue }

                let sourceID = try await ensureSource(bp.source)
                try await insertBook(
                    bp.book,
                    sourceID: sourceID,
                    contentKey: ContentKey.book(forSourceURL: bp.source?.url, kind: bp.source?.kind ?? .localFiles)
                )
                try await insertChapters(bp.chapters, bookID: bp.book.id)
                importedCount += 1
            }

            // Positions must survive books that were re-imported under new UUIDs:
            // resolve each payload position to *local* ids via content keys and
            // upsert last-writer-wins (the old INSERT OR IGNORE silently dropped
            // every position whose raw UUID no longer existed).
            let payloadBookKeys: [UUID: String] = Dictionary(
                uniqueKeysWithValues: payload.books.compactMap { bp in
                    ContentKey.book(forSourceURL: bp.source?.url, kind: bp.source?.kind ?? .localFiles)
                        .map { (bp.book.id, $0) }
                }
            )
            let payloadChapterKeys: [UUID: String] = Dictionary(
                uniqueKeysWithValues: payload.books.flatMap { bp in
                    bp.chapters.map { chapter in
                        (chapter.id, ContentKey.chapter(
                            remoteURL: chapter.remoteURL,
                            localURL: chapter.localURL,
                            index: chapter.index,
                            title: chapter.title
                        ))
                    }
                }
            )

            for position in payload.positions {
                await upsertPosition(
                    position,
                    bookContentKey: payloadBookKeys[position.bookID],
                    chapterContentKey: payloadChapterKeys[position.chapterID]
                )
            }

            for bm in payload.bookmarks {
                guard let id = bm.id else { continue }
                try? await database.execute("""
                INSERT OR IGNORE INTO bookmarks
                    (id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .string(id.uuidString),
                    .string(bm.bookID.uuidString),
                    .string(bm.chapterID.uuidString),
                    .double(bm.position),
                    .string(bm.note ?? ""),
                    .double(bm.createdAt.timeIntervalSince1970),
                    .double(bm.updatedAt.timeIntervalSince1970),
                    .bool(bm.isDeleted)
                ])
            }

            for pl in payload.playlists {
                try? await database.execute("""
                INSERT OR IGNORE INTO playlists (id, title, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """, [
                    .string(pl.playlist.id.uuidString),
                    .string(pl.playlist.title),
                    .double(pl.playlist.createdAt.timeIntervalSince1970),
                    .double(pl.playlist.updatedAt.timeIntervalSince1970)
                ])
                for (offset, bookID) in pl.bookIDs.enumerated() {
                    try? await database.execute("""
                    INSERT OR IGNORE INTO playlist_books (playlist_id, book_id, sort_index)
                    VALUES (?, ?, ?)
                    """, [
                        .string(pl.playlist.id.uuidString),
                        .string(bookID.uuidString),
                        .int(Int64(offset))
                    ])
                }
            }

            for term in payload.tasteTerms {
                try? await database.execute("""
                INSERT OR REPLACE INTO taste_profile_terms (axis, term, weight, last_ts)
                VALUES (?, ?, ?, ?)
                """, [
                    .string(term.axis),
                    .string(term.term),
                    .double(term.weight),
                    .double(Date().timeIntervalSince1970)
                ])
            }
        } catch {
            importError = error.localizedDescription
        }

        return importedCount
    }

    // MARK: - Export helpers

    private func fetchBooks() async throws -> [BackupPayload.BookPayload] {
        let bookRows = try await database.query("SELECT * FROM books")
        var result: [BackupPayload.BookPayload] = []
        for row in bookRows {
            guard let bookIDStr = row.string("id"),
                  let bookID = UUID(uuidString: bookIDStr) else { continue }
            let book = try self.book(from: row)
            let chapters = try await fetchChapters(for: bookID)
            let source = try await fetchSource(for: book.sourceID)
            result.append(BackupPayload.BookPayload(book: book, chapters: chapters, source: source))
        }
        return result
    }

    private func fetchChapters(for bookID: UUID) async throws -> [Chapter] {
        let rows = try await database.query(
            "SELECT * FROM chapters WHERE book_id = ? ORDER BY chapter_index",
            [.string(bookID.uuidString)]
        )
        return rows.compactMap { try? chapter(from: $0) }
    }

    private func fetchSource(for sourceID: UUID) async throws -> Source? {
        let rows = try await database.query(
            "SELECT * FROM sources WHERE id = ? LIMIT 1",
            [.string(sourceID.uuidString)]
        )
        guard let row = rows.first else { return nil }
        return Source(
            id: try ModelMapping.uuid(row, "id"),
            kind: SourceKind(rawValue: row.string("kind") ?? "") ?? .librivox,
            title: row.string("title") ?? "",
            url: row.string("url").flatMap(URL.init(string:)),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0)
        )
    }

    private func fetchPositions() async throws -> [PlaybackPosition] {
        let rows = try await database.query("SELECT * FROM playback_positions")
        return rows.compactMap { try? position(from: $0) }
    }

    private func fetchBookmarks() async throws -> [Bookmark] {
        let rows = try await database.query("SELECT * FROM bookmarks")
        return rows.compactMap { try? bookmark(from: $0) }
    }

    private func fetchPlaylists() async throws -> [BackupPayload.PlaylistPayload] {
        let rows = try await database.query("SELECT * FROM playlists")
        var result: [BackupPayload.PlaylistPayload] = []
        for row in rows {
            guard let idStr = row.string("id"),
                  let id = UUID(uuidString: idStr) else { continue }
            let playlist = Playlist(
                id: id,
                title: row.string("title") ?? "",
                createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
                updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0)
            )
            let bookRows = try await database.query(
                "SELECT book_id FROM playlist_books WHERE playlist_id = ? ORDER BY sort_index",
                [.string(idStr)]
            )
            let bookIDs = bookRows.compactMap { $0.string("book_id").flatMap(UUID.init(uuidString:)) }
            result.append(BackupPayload.PlaylistPayload(playlist: playlist, bookIDs: bookIDs))
        }
        return result
    }

    private func fetchTasteTerms() async throws -> [BackupPayload.TasteTermPayload] {
        let rows = try await database.query("SELECT axis, term, weight FROM taste_profile_terms")
        return rows.compactMap { row in
            guard let axis = row.string("axis"),
                  let term = row.string("term"),
                  let weight = row.double("weight") else { return nil }
            return BackupPayload.TasteTermPayload(axis: axis, term: term, weight: weight)
        }
    }

    // MARK: - Import helpers

    /// Content-key-resolved position upsert, LWW on `updated_at`. Resolves the
    /// payload's book/chapter to local rows by raw UUID first (same-install
    /// restore), then by content key (books re-imported under new UUIDs).
    private func upsertPosition(
        _ position: PlaybackPosition,
        bookContentKey: String?,
        chapterContentKey: String?
    ) async {
        var localBookID: String?
        if let rows = try? await database.query(
            "SELECT id FROM books WHERE id = ? LIMIT 1",
            [.string(position.bookID.uuidString)]
        ), rows.first != nil {
            localBookID = position.bookID.uuidString
        }
        if localBookID == nil, let key = bookContentKey, !key.isEmpty {
            let rows = try? await database.query(
                "SELECT id FROM books WHERE content_key = ? LIMIT 1",
                [.string(key)]
            )
            localBookID = rows?.first?.string("id")
        }
        guard let bookID = localBookID else { return }

        var localChapterID: String?
        if let rows = try? await database.query(
            "SELECT id FROM chapters WHERE book_id = ? AND id = ? LIMIT 1",
            [.string(bookID), .string(position.chapterID.uuidString)]
        ), rows.first != nil {
            localChapterID = position.chapterID.uuidString
        }
        if localChapterID == nil, let key = chapterContentKey, !key.isEmpty {
            let rows = try? await database.query(
                "SELECT id FROM chapters WHERE book_id = ? AND content_key = ? LIMIT 1",
                [.string(bookID), .string(key)]
            )
            localChapterID = rows?.first?.string("id")
        }
        guard let chapterID = localChapterID else { return }

        let localRows = (try? await database.query(
            "SELECT id, updated_at FROM playback_positions WHERE book_id = ? AND chapter_id = ? LIMIT 1",
            [.string(bookID), .string(chapterID)]
        )) ?? []
        let localVersion = localRows.first?.double("updated_at") ?? 0
        guard position.updatedAt.timeIntervalSince1970 > localVersion else { return }
        let rowID = localRows.first?.string("id") ?? position.id.uuidString

        try? await database.execute("""
        INSERT INTO playback_positions
            (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(book_id, chapter_id) DO UPDATE SET
            position_seconds = excluded.position_seconds,
            duration_seconds = excluded.duration_seconds,
            updated_at = excluded.updated_at,
            is_finished = excluded.is_finished
        """, [
            .string(rowID),
            .string(bookID),
            .string(chapterID),
            .double(position.position),
            position.duration.map { .double($0) } ?? .null,
            .double(position.updatedAt.timeIntervalSince1970),
            .bool(position.isFinished)
        ])
    }

    private func bookExists(_ book: Book) async throws -> Bool {
        let rows = try await database.query(
            "SELECT 1 FROM books WHERE id = ? LIMIT 1",
            [.string(book.id.uuidString)]
        )
        return !rows.isEmpty
    }

    private func ensureSource(_ source: Source?) async throws -> UUID {
        guard let source else {
            let unknownID = UUID()
            try? await database.execute("""
            INSERT OR IGNORE INTO sources (id, kind, title, url, created_at)
            VALUES (?, ?, ?, ?, ?)
            """, [
                .string(unknownID.uuidString),
                .string(SourceKind.localFiles.rawValue),
                .string("Unknown (Backup)"),
                .null,
                .double(Date().timeIntervalSince1970)
            ])
            return unknownID
        }

        let existing = try await database.query(
            "SELECT id FROM sources WHERE id = ? LIMIT 1",
            [.string(source.id.uuidString)]
        )
        if existing.isEmpty {
            try await database.execute("""
            INSERT OR IGNORE INTO sources (id, kind, title, url, created_at)
            VALUES (?, ?, ?, ?, ?)
            """, [
                .string(source.id.uuidString),
                .string(source.kind.rawValue),
                .string(source.title),
                source.url.map { .string($0.absoluteString) } ?? .null,
                .double(source.createdAt.timeIntervalSince1970)
            ])
        }
        return source.id
    }

    private func insertBook(_ book: Book, sourceID: UUID, contentKey: String?) async throws {
        let authorsData = try JSONEncoder().encode(book.authors)
        let narratorsData = try JSONEncoder().encode(book.narrators)
        let authorsJSON = String(data: authorsData, encoding: .utf8) ?? "[]"
        let narratorsJSON = String(data: narratorsData, encoding: .utf8) ?? "[]"

        try await database.execute("""
        INSERT OR IGNORE INTO books
            (id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(book.id.uuidString),
            .string(book.title),
            .string(authorsJSON),
            .string(narratorsJSON),
            book.summary.map { .string($0) } ?? .null,
            .string(sourceID.uuidString),
            book.coverURL.map { .string($0.absoluteString) } ?? .null,
            .double(book.createdAt.timeIntervalSince1970),
            .double(book.updatedAt.timeIntervalSince1970),
            .bool(book.isFavorite),
            contentKey.map { .string($0) } ?? .null
        ])
    }

    private func insertChapters(_ chapters: [Chapter], bookID: UUID) async throws {
        for ch in chapters {
            let narratorsData = try JSONEncoder().encode(ch.narrators)
            let narratorsJSON = String(data: narratorsData, encoding: .utf8) ?? "[]"
            let contentKey = ContentKey.chapter(
                remoteURL: ch.remoteURL,
                localURL: ch.localURL,
                index: ch.index,
                title: ch.title
            )

            try await database.execute("""
            INSERT OR IGNORE INTO chapters
                (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json, content_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .string(ch.id.uuidString),
                .string(bookID.uuidString),
                .string(ch.title),
                .string(ch.sortKey),
                .int(Int64(ch.index)),
                ch.duration.map { .double($0) } ?? .null,
                ch.remoteURL.map { .string($0.absoluteString) } ?? .null,
                ch.opusURL.map { .string($0.absoluteString) } ?? .null,
                ch.localURL.map { .string($0.absoluteString) } ?? .null,
                .string(narratorsJSON),
                .string(contentKey)
            ])
        }
    }

    // MARK: - Row parsing

    private func book(from row: DatabaseRow) throws -> Book {
        let authors: [String] = {
            guard let json = row.string("authors_json"),
                  let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }()
        let narrators: [String] = {
            guard let json = row.string("narrators_json"),
                  let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }()
        return Book(
            id: try ModelMapping.uuid(row, "id"),
            title: try row.requiredString("title"),
            authors: authors,
            narrators: narrators,
            summary: row.string("summary"),
            sourceID: try ModelMapping.uuid(row, "source_id"),
            coverURL: row.string("cover_url").flatMap(URL.init(string:)),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0),
            isFavorite: row.bool("is_favorite") ?? false
        )
    }

    private func chapter(from row: DatabaseRow) throws -> Chapter {
        let narrators: [String] = {
            guard let json = row.string("narrators_json"),
                  let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }()
        return Chapter(
            id: try ModelMapping.uuid(row, "id"),
            bookID: try ModelMapping.uuid(row, "book_id"),
            title: try row.requiredString("title"),
            sortKey: row.string("sort_key") ?? "",
            index: Int(row.int("chapter_index") ?? 0),
            duration: row.double("duration_seconds"),
            remoteURL: row.string("remote_url").flatMap(URL.init(string:)),
            opusURL: row.string("opus_url").flatMap(URL.init(string:)),
            localURL: row.string("local_url").flatMap(URL.init(fileURLWithPath:)),
            narrators: narrators
        )
    }

    private func position(from row: DatabaseRow) throws -> PlaybackPosition? {
        guard let idStr = row.string("id"),
              let id = UUID(uuidString: idStr) else { return nil }
        return PlaybackPosition(
            id: id,
            bookID: try ModelMapping.uuid(row, "book_id"),
            chapterID: try ModelMapping.uuid(row, "chapter_id"),
            position: row.double("position_seconds") ?? 0,
            duration: row.double("duration_seconds"),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0),
            isFinished: row.bool("is_finished") ?? false
        )
    }

    private func bookmark(from row: DatabaseRow) throws -> Bookmark? {
        guard let idStr = row.string("id"),
              let id = UUID(uuidString: idStr) else { return nil }
        return Bookmark(
            id: id,
            bookID: try ModelMapping.uuid(row, "book_id"),
            chapterID: try ModelMapping.uuid(row, "chapter_id"),
            position: row.double("position_seconds") ?? 0,
            note: row.string("note"),
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0),
            isDeleted: row.bool("is_deleted") ?? false
        )
    }
}

public extension DateFormatter {
    static let voxglassBackup: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}
