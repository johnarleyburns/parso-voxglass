import Foundation

public enum LibraryBookFilter: Equatable, Hashable, Sendable {
    case all
    case favorites
    case source(UUID)
    case downloaded
    case finished
    case inProgress
}

public enum LibrarySort: Equatable, Sendable {
    case recent
    case title
    case author
    case narrator
    case duration
    case progress

    public func comparator() -> (BookWithChapters, BookWithChapters) -> Bool {
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
public struct BookProgress: Equatable, Sendable {
    public let lastPosition: TimeInterval
    public let isFinished: Bool
}

/// A playable audio file discovered inside a watched folder (§4).
public struct LocalAudioImport: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let sortKey: String
    public let duration: TimeInterval?
}

public final class LibraryRepository {
    private let database: AppDatabase
    private let librivoxClient: LibriVoxCatalogClient?

    public init(database: AppDatabase, librivoxClient: LibriVoxCatalogClient? = nil) {
        self.database = database
        self.librivoxClient = librivoxClient
    }

    public func fetchLibrary() async throws -> [BookWithChapters] {
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

    public func fetchBooks(filteredBy filter: LibraryBookFilter) async throws -> [BookWithChapters] {
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

    public func fetchSources() async throws -> [Source] {
        try await database.prepare()

        let rows = try await database.query("""
        SELECT id, kind, title, url, created_at
        FROM sources
        ORDER BY created_at DESC, title COLLATE NOCASE ASC
        """)
        return try rows.map(Self.source(from:))
    }

    public func fetchRecentlyPlayed(limit: Int = 50) async throws -> [BookWithChapters] {
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

    /// Stable identities for every work that has any saved playback position.
    /// These are used to keep listened items out of recommendation shelves even
    /// when the local UUID differs from the archive.org result identifier.
    public func fetchListenedWorkExclusionKeys() async throws -> Set<String> {
        try await database.prepare()

        let rows = try await database.query("""
        SELECT DISTINCT b.id AS book_id,
               b.title AS title,
               b.authors_json AS authors_json,
               b.content_key AS content_key,
               s.kind AS source_kind,
               s.url AS source_url
        FROM playback_positions p
        JOIN books b ON b.id = p.book_id
        JOIN sources s ON s.id = b.source_id
        """)

        var keys: Set<String> = []
        for row in rows {
            if let bookID = row.string("book_id") {
                keys.insert(bookID)
            }

            let kind = SourceKind(rawValue: row.string("source_kind") ?? "") ?? .localFiles
            let sourceURL = row.string("source_url").flatMap(URL.init(string:))
            let contentKey = row.string("content_key") ?? ContentKey.book(forSourceURL: sourceURL, kind: kind)
            if let contentKey {
                keys.formUnion(Self.exclusionKeys(forContentKey: contentKey))
            }

            let title = row.string("title") ?? ""
            let authors = ModelMapping.authors(from: row)
            keys.insert(WorkKey.normalized(author: authors.isEmpty ? "Unknown author" : authors.joined(separator: ", "), title: title))
        }
        return keys
    }

    /// Deletes a book and everything that cascades from it (chapters, playback
    /// positions, bookmarks, playlist links, taste terms, download records).
    /// Also removes the book's now-orphaned `Source`, since each Internet Archive
    /// import creates its own source row.
    public func deleteBook(_ bookID: UUID) async throws {
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

    public func setFavorite(_ isFavorite: Bool, for bookID: UUID) async throws -> BookWithChapters? {
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

    public func updateNarrators(_ narrators: [String], for bookID: UUID) async throws {
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
    public func backfillMissingNarrators() async throws -> Int {
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

    /// Backfills `content_key` for books and chapters imported before migration 7,
    /// deriving each key from data already in the database (source URL/kind for
    /// books; audio filename stem for chapters). Idempotent — only NULL keys are
    /// touched, so this is cheap on every launch after the first.
    @discardableResult
    public func backfillContentKeysIfNeeded() async -> Int {
        do {
            try await database.prepare()
            var updated = 0

            let bookRows = try await database.query("""
            SELECT b.id AS book_id, s.url AS source_url, s.kind AS source_kind
            FROM books b JOIN sources s ON s.id = b.source_id
            WHERE b.content_key IS NULL
            """)
            for row in bookRows {
                guard let bookID = row.string("book_id") else { continue }
                let kind = SourceKind(rawValue: row.string("source_kind") ?? "") ?? .localFiles
                let url = row.string("source_url").flatMap(URL.init(string:))
                guard let key = ContentKey.book(forSourceURL: url, kind: kind) else { continue }
                try await database.execute(
                    "UPDATE books SET content_key = ? WHERE id = ?",
                    [.string(key), .string(bookID)]
                )
                updated += 1
            }

            let chapterRows = try await database.query("""
            SELECT id, title, chapter_index, remote_url, local_url
            FROM chapters
            WHERE content_key IS NULL
            """)
            for row in chapterRows {
                guard let chapterID = row.string("id") else { continue }
                let key = ContentKey.chapter(
                    remoteURL: row.string("remote_url").flatMap(URL.init(string:)),
                    localURL: row.string("local_url").flatMap(URL.init(string:)),
                    index: Int(row.int("chapter_index") ?? 0),
                    title: row.string("title") ?? ""
                )
                try await database.execute(
                    "UPDATE chapters SET content_key = ? WHERE id = ?",
                    [.string(key), .string(chapterID)]
                )
                updated += 1
            }
            return updated
        } catch {
            return 0
        }
    }

    /// Books imported before taste capture existed (2026-07-11) have no
    /// book_taste rows, so their listening history is invisible to the
    /// recommendation profile. Seed author terms from the locally stored
    /// authors for any book with zero book_taste rows; when no usable author
    /// exists, seed a subject term from the title so played books still
    /// contribute taste (`tasteSeedTerms`). Idempotent.
    @discardableResult
    public func backfillBookTasteIfNeeded() async -> Int {
        do {
            try await database.prepare()
            let rows = try await database.query("""
            SELECT b.id, b.title, b.authors_json FROM books b LEFT JOIN book_taste bt ON
            bt.book_id = b.id WHERE bt.book_id IS NULL
            """)
            var count = 0
            for row in rows {
                guard let bookID = row.string("id") else { continue }
                let authors = (row.string("authors_json")?.data(using: .utf8))
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                let terms = Self.tasteSeedTerms(authors: authors, title: row.string("title") ?? "")
                guard !terms.isEmpty else { continue }
                for term in terms {
                    try? await database.execute(
                        "INSERT OR IGNORE INTO book_taste (book_id, axis, term) VALUES (?, ?, ?)",
                        [.string(bookID), .string(term.axis), .string(term.term)]
                    )
                }
                count += 1
            }
            return count
        } catch {
            return 0
        }
    }

    /// Pure decision: which taste terms a book contributes when it has no
    /// book_taste rows. Usable authors win; otherwise the title seeds a subject
    /// term so played books with placeholder authors stay visible to taste.
    public static func tasteSeedTerms(authors: [String], title: String) -> [(axis: String, term: String)] {
        let placeholders: Set<String> = ["unknown", "unknown author", "various", "internet archive", "local files"]
        let authorTerms = authors
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !placeholders.contains($0.lowercased()) }
            .map { (axis: "author", term: $0.lowercased()) }
        if !authorTerms.isEmpty {
            return authorTerms
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedTitle.isEmpty else { return [] }
        return [(axis: "subject", term: trimmedTitle)]
    }

    /// Returns all taste terms (axis, term) for a given book, for seeding
    /// the taste profile when the book is listened to.
    public func fetchBookTasteTerms(for bookID: UUID) async throws -> [(axis: String, term: String)] {
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

    public func importInternetArchiveItem(
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
            coverURL: Self.bestCoverURL(identifier: identifier, metadata: metadata),
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

        try await insert(
            book: book,
            chapters: chapters,
            bookContentKey: ContentKey.book(forInternetArchiveIdentifier: identifier)
        )

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
    public func importLocalFolder(
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
            try await insert(
                book: book,
                chapters: [],
                bookContentKey: ContentKey.book(forLocalFolderName: folderName)
            )
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
            let chapterKey = ContentKey.chapter(
                remoteURL: nil,
                localURL: file.url,
                index: chapter.index,
                title: file.title
            )
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json, content_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                .string(ModelMapping.narratorsJSON(chapter.narrators)),
                .string(chapterKey)
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

    /// Aggregates playback-progress per book. A book is finished only when
    /// *every* chapter has a finished row (Phase 4 — the old `MIN(is_finished)`
    /// over only-positioned chapters marked a book finished off one finished
    /// chapter). Progress is Σ(finished chapter durations) + the current chapter's
    /// offset, not the largest within-chapter offset.
    public func fetchBookProgress() async throws -> [UUID: BookProgress] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT p.book_id AS book_id,
               SUM(CASE WHEN p.is_finished = 1 THEN 1 ELSE 0 END) AS finished_chapters,
               (SELECT COUNT(*) FROM chapters c WHERE c.book_id = p.book_id) AS total_chapters,
               SUM(CASE WHEN p.is_finished = 1 THEN COALESCE(p.duration_seconds, 0) ELSE 0 END) AS finished_duration,
               COALESCE((
                   SELECT p2.position_seconds FROM playback_positions p2
                   WHERE p2.book_id = p.book_id AND p2.is_finished = 0
                   ORDER BY p2.updated_at DESC LIMIT 1
               ), 0) AS current_offset
        FROM playback_positions p
        GROUP BY p.book_id
        """)
        var result: [UUID: BookProgress] = [:]
        for row in rows {
            let bookID = try ModelMapping.uuid(row, "book_id")
            let finishedChapters = row.int("finished_chapters") ?? 0
            let totalChapters = row.int("total_chapters") ?? 0
            let finishedDuration = row.double("finished_duration") ?? 0
            let currentOffset = row.double("current_offset") ?? 0
            result[bookID] = BookProgress(
                lastPosition: finishedDuration + currentOffset,
                isFinished: totalChapters > 0 && finishedChapters >= totalChapters
            )
        }
        return result
    }

    // MARK: - Download records (offline downloads, §7)

    /// Replaces all download records for a book with a fresh set (used when a
    /// new offline download is enqueued).
    public func replaceDownloadRecords(_ records: [DownloadRecord], forBookID bookID: UUID) async throws {
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

    public func updateDownloadRecord(
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

    public func deleteDownloadRecords(forBookID bookID: UUID) async throws {
        try await database.prepare()
        try await database.execute(
            "DELETE FROM download_records WHERE book_id = ?",
            [ModelMapping.databaseValue(bookID)]
        )
    }

    public func fetchDownloadRecords(forBookID bookID: UUID) async throws -> [DownloadRecord] {
        try await database.prepare()
        let rows = try await database.query("""
        SELECT id, book_id, chapter_id, state, local_url, bytes_downloaded, bytes_expected, updated_at
        FROM download_records
        WHERE book_id = ?
        """, [ModelMapping.databaseValue(bookID)])
        return try rows.map(Self.downloadRecord(from:))
    }

    public func fetchAllDownloadRecords() async throws -> [DownloadRecord] {
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

    public static func bestCoverURL(identifier: String, metadata: InternetArchiveMetadata) -> URL? {
        let primaryURL = InternetArchiveMetadata.coverURL(for: identifier)
        let coverFiles = metadata.coverImageFiles
        if let bestCover = coverFiles.first, let fileURL = metadata.fileURL(for: bestCover) {
            return fileURL
        }
        return primaryURL
    }

    private func insert(book: Book, chapters: [Chapter], bookContentKey: String? = nil) async throws {
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, narrators_json, summary, source_id, cover_url, created_at, updated_at, is_favorite, content_key)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            .bool(book.isFavorite),
            bookContentKey.map { .string($0) } ?? .null
        ])

        for chapter in chapters {
            let chapterKey = ContentKey.chapter(
                remoteURL: chapter.remoteURL,
                localURL: chapter.localURL,
                index: chapter.index,
                title: chapter.title
            )
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, opus_url, local_url, narrators_json, content_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                .string(ModelMapping.narratorsJSON(chapter.narrators)),
                .string(chapterKey)
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

    private static func exclusionKeys(forContentKey contentKey: String) -> Set<String> {
        let trimmed = contentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys: Set<String> = [trimmed]
        if trimmed.hasPrefix("ia:") {
            let identifier = String(trimmed.dropFirst(3))
            if !identifier.isEmpty {
                keys.insert(identifier)
            }
        }
        return keys
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
