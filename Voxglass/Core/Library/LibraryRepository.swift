import Foundation

enum LibraryBookFilter: Equatable, Hashable, Sendable {
    case all
    case favorites
    case source(UUID)
    case downloaded
    case finished
    case inProgress
}

enum LibrarySort: Equatable, Sendable {
    case recent
    case title
    case author
    case narrator
    case duration
    case progress

    func comparator() -> (BookWithChapters, BookWithChapters) -> Bool {
        switch self {
        case .recent:
            return { $0.book.updatedAt > $1.book.updatedAt }
        case .title:
            return { $0.book.title.localizedCaseInsensitiveCompare($1.book.title) == .orderedAscending }
        case .author:
            return {
                let a = $0.book.authors.first ?? ""
                let b = $1.book.authors.first ?? ""
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        case .narrator:
            return {
                let a = $0.book.narrators.first ?? ""
                let b = $1.book.narrators.first ?? ""
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        case .duration:
            return {
                ($0.totalDuration ?? .greatestFiniteMagnitude) < ($1.totalDuration ?? .greatestFiniteMagnitude)
            }
        case .progress:
            return { ($0.book.updatedAt) > ($1.book.updatedAt) }
        }
    }
}

/// Aggregated playback progress for a single book (P1-2).
struct BookProgress: Equatable, Sendable {
    let lastPosition: TimeInterval
    let isFinished: Bool
}

/// A playable audio file discovered inside a watched folder (§4).
struct LocalAudioImport: Equatable, Sendable {
    let url: URL
    let title: String
    let sortKey: String
    let duration: TimeInterval?
}

final class LibraryRepository {
    private let database: AppDatabase
    private let librivoxClient: LibriVoxCatalogClient?

    init(database: AppDatabase, librivoxClient: LibriVoxCatalogClient? = nil) {
        self.database = database
        self.librivoxClient = librivoxClient
    }

    func fetchLibrary() async throws -> [BookWithChapters] {
        try await database.prepare()

        let bookRows = try await database.query("""
        SELECT id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite
        FROM books
        ORDER BY updated_at DESC, title COLLATE NOCASE ASC
        """)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json
        FROM chapters
        ORDER BY chapter_index ASC, sort_key COLLATE NOCASE ASC
        """)

        let chaptersByBook = try Dictionary(grouping: chapterRows.map(Self.chapter(from:)), by: \.bookID)
        return try bookRows.map { row in
            let book = try Self.book(from: row)
            return BookWithChapters(book: book, chapters: (chaptersByBook[book.id] ?? []).naturallySorted())
        }
    }

    func fetchBooks(filteredBy filter: LibraryBookFilter) async throws -> [BookWithChapters] {
        let library = try await fetchLibrary()

        switch filter {
        case .all:
            return library
        case .favorites:
            return library.filter(\.book.isFavorite)
        case .source(let sourceID):
            return library.filter { $0.book.sourceID == sourceID }
        case .downloaded:
            let downloadedIDs = try await downloadedBookIDs()
            return library.filter { downloadedIDs.contains($0.book.id) }
        case .finished:
            let progress = try await fetchBookProgress()
            return library.filter { progress[$0.book.id]?.isFinished == true }
        case .inProgress:
            let progress = try await fetchBookProgress()
            return library.filter { book in
                guard let p = progress[book.book.id] else { return false }
                return !p.isFinished && p.lastPosition > 0
            }
        }
    }

    func fetchSources() async throws -> [Source] {
        try await database.prepare()

        let rows = try await database.query("""
        SELECT id, kind, title, url, created_at
        FROM sources
        ORDER BY created_at DESC, title COLLATE NOCASE ASC
        """)
        return try rows.map(Self.source(from:))
    }

    func fetchRecentlyPlayed(limit: Int = 50) async throws -> [BookWithChapters] {
        try await database.prepare()

        let rows = try await database.query("""
        SELECT book_id, MAX(updated_at) AS latest_position_at
        FROM playback_positions
        GROUP BY book_id
        ORDER BY latest_position_at DESC
        LIMIT ?
        """, [
            .int(Int64(max(0, limit)))
        ])
        let orderedIDs = try rows.map { try ModelMapping.uuid($0, "book_id") }
        let libraryByID = Dictionary(uniqueKeysWithValues: try await fetchLibrary().map { ($0.book.id, $0) })
        return orderedIDs.compactMap { libraryByID[$0] }
    }

    /// Deletes a book and everything that cascades from it (chapters, playback
    /// positions, bookmarks, playlist links, taste terms, download records).
    /// Also removes the book's now-orphaned `Source`, since each Internet Archive
    /// import creates its own source row.
    func deleteBook(_ bookID: UUID) async throws {
        try await database.prepare()

        let rows = try await database.query(
            "SELECT source_id FROM books WHERE id = ? LIMIT 1",
            [ModelMapping.databaseValue(bookID)]
        )
        var sourceID: UUID?
        if let row = rows.first {
            sourceID = try ModelMapping.uuid(row, "source_id")
        }

        // download_records cascade via FK ON DELETE CASCADE, along with chapters,
        // playback_positions, bookmarks, playlist_books, and book_taste.
        try await database.execute(
            "DELETE FROM books WHERE id = ?",
            [ModelMapping.databaseValue(bookID)]
        )

        if let sourceID {
            let remaining = try await database.query(
                "SELECT COUNT(*) AS count FROM books WHERE source_id = ?",
                [ModelMapping.databaseValue(sourceID)]
            )
            let count = remaining.first?.int("count") ?? 0
            if count == 0 {
                try await database.execute(
                    "DELETE FROM sources WHERE id = ?",
                    [ModelMapping.databaseValue(sourceID)]
                )
            }
        }
    }

    func setFavorite(_ isFavorite: Bool, for bookID: UUID) async throws -> BookWithChapters? {
        try await database.prepare()

        try await database.execute("""
        UPDATE books
        SET is_favorite = ?
        WHERE id = ?
        """, [
            .bool(isFavorite),
            ModelMapping.databaseValue(bookID)
        ])
        return try await bookWithChapters(forBookID: bookID)
    }

    func updateNarrators(_ narrators: [String], for bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute("""
        UPDATE books
        SET narrators_json = ?
        WHERE id = ?
        """, [
            .string(ModelMapping.narratorsJSON(narrators)),
            ModelMapping.databaseValue(bookID)
        ])
    }

    /// One-time best-effort pass over already-imported books whose narrators are
    /// empty: extract names from the stored summary and persist them. Returns the
    /// number of books that were updated.
    @discardableResult
    func backfillMissingNarrators() async throws -> Int {
        try await database.prepare()
        let rows = try await database.query(
            "SELECT id, summary FROM books WHERE narrators_json = '[]' OR narrators_json IS NULL",
            []
        )
        var updated = 0
        for row in rows {
            guard let summary = row.string("summary") else { continue }
            let narrators = NarratorExtractor.extract(from: summary)
            guard !narrators.isEmpty else { continue }
            let bookID = try ModelMapping.uuid(row, "id")
            try await updateNarrators(narrators, for: bookID)
            updated += 1
        }
        return updated
    }

    /// Returns all taste terms (axis, term) for a given book, for seeding
    /// the taste profile when the book is listened to.
    func fetchBookTasteTerms(for bookID: UUID) async throws -> [(axis: String, term: String)] {
        try await database.prepare()
        let rows = try await database.query(
            "SELECT axis, term FROM book_taste WHERE book_id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
        return rows.compactMap { row in
            guard let axis = row.string("axis"), let term = row.string("term") else { return nil }
            return (axis, term)
        }
    }

    func importInternetArchiveItem(
        _ metadata: InternetArchiveMetadata,
        sourceKind: SourceKind
    ) async throws -> BookWithChapters {
        let identifier = metadata.identifier
        guard !identifier.isEmpty else {
            throw InternetArchiveError.missingIdentifier
        }

        let selectedFiles = metadata.selectedAudioFiles
        guard !selectedFiles.isEmpty else {
            throw InternetArchiveError.noPlayableAudio(identifier)
        }

        let source = try await ensureInternetArchiveSource(
            identifier: identifier,
            title: metadata.title,
            sourceKind: sourceKind
        )
        if let existing = try await bookWithChapters(forSourceID: source.id) {
            return existing
        }

        let now = Date()
        var book = Book(
            title: metadata.title,
            authors: metadata.creators.isEmpty ? ["Internet Archive"] : metadata.creators,
            summary: metadata.summary,
            sourceID: source.id,
            coverURL: InternetArchiveMetadata.coverURL(for: identifier),
            createdAt: now,
            updatedAt: now
        )
        // Build lookup of Opus files by chapter key so we can attach opusURL to each chapter
        let opusFilesByChapter: [String: InternetArchiveFile] = {
            let opusFiles = metadata.files.filter {
                AudioFormatSelection.codec(for: $0.format, filename: $0.name) == .opus
            }
            var dict: [String: InternetArchiveFile] = [:]
            for file in opusFiles {
                let key = InternetArchiveAudioSelector.chapterTitle(for: file)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
                if dict[key] == nil {
                    dict[key] = file
                }
            }
            return dict
        }()

        var chapters = selectedFiles.enumerated().compactMap { index, file -> Chapter? in
            guard let remoteURL = metadata.fileURL(for: file) else { return nil }
            let chapterTitle = InternetArchiveAudioSelector.chapterTitle(for: file)
            let key = chapterTitle
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
            let opusFile = opusFilesByChapter[key]
            let opusURL = opusFile.flatMap { metadata.fileURL(for: $0) }
            return Chapter(
                bookID: book.id,
                title: chapterTitle,
                sortKey: file.track ?? file.name,
                index: index,
                duration: file.duration,
                remoteURL: remoteURL,
                opusURL: opusURL
            )
        }

        guard !chapters.isEmpty else {
            throw InternetArchiveError.noPlayableAudio(identifier)
        }

        try await enrichNarrators(
            book: &book,
            chapters: &chapters,
            metadata: metadata,
            sourceKind: sourceKind
        )

        try await insert(book: book, chapters: chapters)

        // Capture taste metadata for the recommendation engine
        let bookIDString = book.id.uuidString
        for author in metadata.creators {
            let trimmed = author.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "Unknown", trimmed != "Various" else { continue }
            try? await database.execute(
                "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'author', ?)",
                [.string(bookIDString), .string(trimmed.lowercased())]
            )
        }
        for subject in metadata.metadata.subjects {
            let trimmed = subject.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            try? await database.execute(
                "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'subject', ?)",
                [.string(bookIDString), .string(trimmed.lowercased())]
            )
        }
        if let language = metadata.metadata.language?.trimmingCharacters(in: .whitespaces), !language.isEmpty {
            try? await database.execute(
                "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, 'language', ?)",
                [.string(bookIDString), .string(language.lowercased())]
            )
        }

        return BookWithChapters(book: book, chapters: chapters)
    }

    // MARK: - Local folder import (Folder Watch, §4)

    /// Imports (or re-syncs) a watched folder: one `localFiles` source + one book
    /// per folder, one chapter per audio file. Idempotent — re-scanning only
    /// appends chapters for files not already present, so no duplicates.
    @discardableResult
    func importLocalFolder(
        folderURL: URL,
        folderName: String,
        files: [LocalAudioImport]
    ) async throws -> BookWithChapters {
        try await database.prepare()
        let source = try await ensureLocalSource(folderURL: folderURL, title: folderName)

        let existing = try await bookWithChapters(forSourceID: source.id)
        let book: Book
        if let existing {
            book = existing.book
        } else {
            let now = Date()
            book = Book(
                title: folderName,
                authors: ["Local Files"],
                summary: nil,
                sourceID: source.id,
                coverURL: nil,
                createdAt: now,
                updatedAt: now
            )
            try await insert(book: book, chapters: [])
        }

        let knownURLs = Set((existing?.chapters ?? []).compactMap { $0.localURL?.absoluteString })
        let startIndex = existing?.chapters.count ?? 0
        let newFiles = files.filter { !knownURLs.contains($0.url.absoluteString) }

        for (offset, file) in newFiles.enumerated() {
            let chapter = Chapter(
                bookID: book.id,
                title: file.title,
                sortKey: file.sortKey,
                index: startIndex + offset,
                duration: file.duration,
                remoteURL: nil,
                opusURL: nil,
                localURL: file.url
            )
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                ModelMapping.databaseValue(chapter.id),
                ModelMapping.databaseValue(chapter.bookID),
                .string(chapter.title),
                .string(chapter.sortKey),
                .int(Int64(chapter.index)),
                ModelMapping.databaseValue(chapter.duration),
                .null,
                .null,
                ModelMapping.databaseValue(chapter.localURL),
                .string(ModelMapping.narratorsJSON(chapter.narrators))
            ])
        }

        return try await bookWithChapters(forSourceID: source.id)
            ?? BookWithChapters(book: book, chapters: [])
    }

    private func ensureLocalSource(folderURL: URL, title: String) async throws -> Source {
        let existing = try await database.query(
            "SELECT id, kind, title, url, created_at FROM sources WHERE url = ? AND kind = ? LIMIT 1",
            [ModelMapping.databaseValue(folderURL), .string(SourceKind.localFiles.rawValue)]
        )
        if let row = existing.first {
            return try Self.source(from: row)
        }

        let source = Source(kind: .localFiles, title: title, url: folderURL)
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            ModelMapping.databaseValue(source.id),
            .string(source.kind.rawValue),
            .string(source.title),
            ModelMapping.databaseValue(source.url),
            ModelMapping.databaseValue(source.createdAt)
        ])
        return source
    }

    private func ensureInternetArchiveSource(
        identifier: String,
        title: String,
        sourceKind: SourceKind
    ) async throws -> Source {
        let detailsURL = InternetArchiveMetadata.detailsURL(for: identifier)
        let existing = try await database.query(
            "SELECT id, kind, title, url, created_at FROM sources WHERE url = ? LIMIT 1",
            [ModelMapping.databaseValue(detailsURL)]
        )
        if let row = existing.first {
            return try Self.source(from: row)
        }

        let source = Source(
            kind: sourceKind,
            title: title,
            url: detailsURL
        )
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            ModelMapping.databaseValue(source.id),
            .string(source.kind.rawValue),
            .string(source.title),
            ModelMapping.databaseValue(source.url),
            ModelMapping.databaseValue(source.createdAt)
        ])
        return source
    }

    private func bookWithChapters(forSourceID sourceID: UUID) async throws -> BookWithChapters? {
        let bookRows = try await database.query("""
        SELECT id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite
        FROM books
        WHERE source_id = ?
        LIMIT 1
        """, [ModelMapping.databaseValue(sourceID)])
        guard let bookRow = bookRows.first else { return nil }

        let book = try Self.book(from: bookRow)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json
        FROM chapters
        WHERE book_id = ?
        ORDER BY chapter_index ASC, sort_key COLLATE NOCASE ASC
        """, [ModelMapping.databaseValue(book.id)])
        return BookWithChapters(book: book, chapters: try chapterRows.map(Self.chapter(from:)).naturallySorted())
    }

    private func bookWithChapters(forBookID bookID: UUID) async throws -> BookWithChapters? {
        let bookRows = try await database.query("""
        SELECT id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite
        FROM books
        WHERE id = ?
        LIMIT 1
        """, [ModelMapping.databaseValue(bookID)])
        guard let bookRow = bookRows.first else { return nil }

        let book = try Self.book(from: bookRow)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json
        FROM chapters
        WHERE book_id = ?
        ORDER BY chapter_index ASC, sort_key COLLATE NOCASE ASC
        """, [ModelMapping.databaseValue(bookID)])
        return BookWithChapters(book: book, chapters: try chapterRows.map(Self.chapter(from:)).naturallySorted())
    }

    private func downloadedBookIDs() async throws -> Set<UUID> {
        let rows = try await database.query("""
        SELECT DISTINCT book_id
        FROM download_records
        WHERE state IN ('downloaded', 'complete', 'completed') OR local_url IS NOT NULL
        """)
        return Set(try rows.map { try ModelMapping.uuid($0, "book_id") })
    }

    /// Aggregates playback-progress per book: last position and whether every
    /// chapter row has `is_finished = 1`. Books with no entries are absent.
    func fetchBookProgress() async throws -> [UUID: BookProgress] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT book_id, MAX(position_seconds) AS last_position,
               MIN(is_finished) AS all_finished
        FROM playback_positions
        GROUP BY book_id
        """)
        var result: [UUID: BookProgress] = [:]
        for row in rows {
            let bookID = try ModelMapping.uuid(row, "book_id")
            result[bookID] = BookProgress(
                lastPosition: row.double("last_position") ?? 0,
                isFinished: row.bool("all_finished") ?? false
            )
        }
        return result
    }

    // MARK: - Download records (offline downloads, §7)

    /// Replaces all download records for a book with a fresh set (used when a
    /// new offline download is enqueued).
    func replaceDownloadRecords(_ records: [DownloadRecord], forBookID bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute(
            "DELETE FROM download_records WHERE book_id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
        for record in records {
            try await database.execute("""
            INSERT INTO download_records
                (id, book_id, chapter_id, state, local_url, bytes_downloaded, bytes_expected, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                ModelMapping.databaseValue(record.id),
                ModelMapping.databaseValue(record.bookID),
                record.chapterID.map { ModelMapping.databaseValue($0) } ?? .null,
                .string(record.state.rawValue),
                ModelMapping.databaseValue(record.localURL),
                .int(record.bytesDownloaded),
                ModelMapping.databaseValue(record.bytesExpected),
                ModelMapping.databaseValue(record.updatedAt)
            ])
        }
    }

    func updateDownloadRecord(
        bookID: UUID,
        chapterID: UUID,
        state: DownloadState,
        localURL: URL? = nil,
        bytesDownloaded: Int64? = nil
    ) async throws {
        try await database.prepare()
        try await database.execute("""
        UPDATE download_records
        SET state = ?, local_url = COALESCE(?, local_url),
            bytes_downloaded = COALESCE(?, bytes_downloaded), updated_at = ?
        WHERE book_id = ? AND chapter_id = ?
        """, [
            .string(state.rawValue),
            ModelMapping.databaseValue(localURL),
            ModelMapping.databaseValue(bytesDownloaded),
            ModelMapping.databaseValue(Date()),
            ModelMapping.databaseValue(bookID),
            ModelMapping.databaseValue(chapterID)
        ])
    }

    func deleteDownloadRecords(forBookID bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute(
            "DELETE FROM download_records WHERE book_id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
    }

    func fetchDownloadRecords(forBookID bookID: UUID) async throws -> [DownloadRecord] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, state, local_url, bytes_downloaded, bytes_expected, updated_at
        FROM download_records
        WHERE book_id = ?
        """, [ModelMapping.databaseValue(bookID)])
        return try rows.map(Self.downloadRecord(from:))
    }

    func fetchAllDownloadRecords() async throws -> [DownloadRecord] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, state, local_url, bytes_downloaded, bytes_expected, updated_at
        FROM download_records
        """)
        return try rows.map(Self.downloadRecord(from:))
    }

    // MARK: - Narrator enrichment (Phase 4C)

    private func enrichNarrators(
        book: inout Book,
        chapters: inout [Chapter],
        metadata: InternetArchiveMetadata,
        sourceKind: SourceKind
    ) async throws {
        defer {
            if book.narrators.isEmpty {
                book.narrators = NarratorExtractor.extract(from: book.summary ?? metadata.metadata.description)
            }
        }

        guard sourceKind == .librivox,
              let callNumberRaw = metadata.metadata.callNumber,
              let librivoxBookID = Int(callNumberRaw) else { return }

        let client = librivoxClient ?? LibriVoxClient()

        let sections: [LibriVoxSection]
        do {
            sections = try await client.fetchSections(bookID: librivoxBookID)
        } catch {
            return
        }
        guard !sections.isEmpty else { return }

        let chapterNarrators = NarratorMatcher.match(
            chapters: chapters,
            sections: sections,
            archiveIdentifier: metadata.identifier
        )

        if chapterNarrators.isEmpty {
            let bookNarrators = NarratorMatcher.bookLevelNarrators(from: sections)
            if !bookNarrators.isEmpty {
                book.narrators = bookNarrators
            }
        } else {
            for i in chapters.indices {
                chapters[i].narrators = chapterNarrators[chapters[i].id] ?? []
            }
            var seen: Set<String> = []
            var ordered: [String] = []
            for chapter in chapters {
                for name in chapter.narrators {
                    if seen.insert(name).inserted {
                        ordered.append(name)
                    }
                }
            }
            book.narrators = ordered
        }
    }

    private func insert(book: Book, chapters: [Chapter]) async throws {
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            ModelMapping.databaseValue(book.id),
            .string(book.title),
            .string(ModelMapping.authorsJSON(book.authors)),
            .string(ModelMapping.narratorsJSON(book.narrators)),
            ModelMapping.databaseValue(book.summary),
            ModelMapping.databaseValue(book.sourceID),
            ModelMapping.databaseValue(book.coverURL),
            ModelMapping.databaseValue(book.createdAt),
            ModelMapping.databaseValue(book.updatedAt),
            .bool(book.isFavorite)
        ])

        for chapter in chapters {
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                ModelMapping.databaseValue(chapter.id),
                ModelMapping.databaseValue(chapter.bookID),
                .string(chapter.title),
                .string(chapter.sortKey),
                .int(Int64(chapter.index)),
                ModelMapping.databaseValue(chapter.duration),
                ModelMapping.databaseValue(chapter.remoteURL),
                ModelMapping.databaseValue(chapter.opusURL),
                ModelMapping.databaseValue(chapter.localURL),
                .string(ModelMapping.narratorsJSON(chapter.narrators))
            ])
        }
    }

    private static func source(from row: DatabaseRow) throws -> Source {
        Source(
            id: try ModelMapping.uuid(row, "id"),
            kind: SourceKind(rawValue: try row.requiredString("kind")) ?? .localFiles,
            title: try row.requiredString("title"),
            url: ModelMapping.url(row, "url"),
            createdAt: ModelMapping.date(row, "created_at")
        )
    }

    private static func book(from row: DatabaseRow) throws -> Book {
        Book(
            id: try ModelMapping.uuid(row, "id"),
            title: try row.requiredString("title"),
            authors: ModelMapping.authors(from: row),
            narrators: ModelMapping.narrators(from: row),
            summary: row.string("summary"),
            sourceID: try ModelMapping.uuid(row, "source_id"),
            coverURL: ModelMapping.url(row, "cover_url"),
            createdAt: ModelMapping.date(row, "created_at"),
            updatedAt: ModelMapping.date(row, "updated_at"),
            isFavorite: row.bool("is_favorite") ?? false
        )
    }

    private static func chapter(from row: DatabaseRow) throws -> Chapter {
        Chapter(
            id: try ModelMapping.uuid(row, "id"),
            bookID: try ModelMapping.uuid(row, "book_id"),
            title: try row.requiredString("title"),
            sortKey: try row.requiredString("sort_key"),
            index: Int(row.int("chapter_index") ?? 0),
            duration: row.double("duration_seconds"),
            remoteURL: ModelMapping.url(row, "remote_url"),
            opusURL: ModelMapping.url(row, "opus_url"),
            localURL: ModelMapping.url(row, "local_url"),
            narrators: ModelMapping.narrators(from: row)
        )
    }

    private static func downloadRecord(from row: DatabaseRow) throws -> DownloadRecord {
        DownloadRecord(
            id: try ModelMapping.uuid(row, "id"),
            bookID: try ModelMapping.uuid(row, "book_id"),
            chapterID: row.string("chapter_id").flatMap(UUID.init(uuidString:)),
            state: DownloadState(rawValue: try row.requiredString("state")) ?? .queued,
            localURL: ModelMapping.url(row, "local_url"),
            bytesDownloaded: row.int("bytes_downloaded") ?? 0,
            bytesExpected: row.int("bytes_expected"),
            updatedAt: ModelMapping.date(row, "updated_at")
        )
    }
}
