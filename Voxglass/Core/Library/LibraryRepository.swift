import Foundation

enum LibraryBookFilter: Equatable, Sendable {
    case all
    case favorites
    case source(UUID)
    case downloaded
}

final class LibraryRepository {
    private let database: AppDatabase
    private let importer: LocalAudioImporter

    init(database: AppDatabase, importer: LocalAudioImporter = LocalAudioImporter()) {
        self.database = database
        self.importer = importer
    }

    func fetchLibrary() async throws -> [BookWithChapters] {
        try await database.prepare()

        let bookRows = try await database.query("""
        SELECT id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite
        FROM books
        ORDER BY updated_at DESC, title COLLATE NOCASE ASC
        """)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url
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

    func importLocalAudio(from urls: [URL]) async throws -> [BookWithChapters] {
        let importedFiles = try await importer.importAudio(from: urls)
        guard !importedFiles.isEmpty else { return [] }

        let source = try await ensureLocalFilesSource()
        var importedBooks: [BookWithChapters] = []

        for imported in importedFiles {
            let now = Date()
            let book = Book(
                title: imported.title,
                authors: ["Local File"],
                summary: "Imported from this device. Voxglass keeps this file and its listening state on device.",
                sourceID: source.id,
                createdAt: now,
                updatedAt: now
            )
            let chapter = Chapter(
                bookID: book.id,
                title: imported.title,
                sortKey: imported.title,
                index: 0,
                duration: imported.duration,
                localURL: imported.localURL
            )
            try await insert(book: book, chapters: [chapter])
            importedBooks.append(BookWithChapters(book: book, chapters: [chapter]))
        }

        return importedBooks
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
        let book = Book(
            title: metadata.title,
            authors: metadata.creators.isEmpty ? ["Internet Archive"] : metadata.creators,
            summary: metadata.summary,
            sourceID: source.id,
            coverURL: InternetArchiveMetadata.coverURL(for: identifier),
            createdAt: now,
            updatedAt: now
        )
        let chapters = selectedFiles.enumerated().compactMap { index, file -> Chapter? in
            guard let remoteURL = metadata.fileURL(for: file) else { return nil }
            return Chapter(
                bookID: book.id,
                title: InternetArchiveAudioSelector.chapterTitle(for: file),
                sortKey: file.track ?? file.name,
                index: index,
                duration: file.duration,
                remoteURL: remoteURL
            )
        }

        guard !chapters.isEmpty else {
            throw InternetArchiveError.noPlayableAudio(identifier)
        }

        try await insert(book: book, chapters: chapters)
        return BookWithChapters(book: book, chapters: chapters)
    }

    private func ensureLocalFilesSource() async throws -> Source {
        let existing = try await database.query(
            "SELECT id, kind, title, url, created_at FROM sources WHERE kind = ? LIMIT 1",
            [.string(SourceKind.localFiles.rawValue)]
        )
        if let row = existing.first {
            return try Self.source(from: row)
        }

        let source = Source(kind: .localFiles, title: "Local Files")
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
        SELECT id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite
        FROM books
        WHERE source_id = ?
        LIMIT 1
        """, [ModelMapping.databaseValue(sourceID)])
        guard let bookRow = bookRows.first else { return nil }

        let book = try Self.book(from: bookRow)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url
        FROM chapters
        WHERE book_id = ?
        ORDER BY chapter_index ASC, sort_key COLLATE NOCASE ASC
        """, [ModelMapping.databaseValue(book.id)])
        return BookWithChapters(book: book, chapters: try chapterRows.map(Self.chapter(from:)).naturallySorted())
    }

    private func bookWithChapters(forBookID bookID: UUID) async throws -> BookWithChapters? {
        let bookRows = try await database.query("""
        SELECT id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite
        FROM books
        WHERE id = ?
        LIMIT 1
        """, [ModelMapping.databaseValue(bookID)])
        guard let bookRow = bookRows.first else { return nil }

        let book = try Self.book(from: bookRow)
        let chapterRows = try await database.query("""
        SELECT id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url
        FROM chapters
        WHERE book_id = ?
        ORDER BY chapter_index ASC, sort_key COLLATE NOCASE ASC
        """, [ModelMapping.databaseValue(book.id)])
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

    private func insert(book: Book, chapters: [Chapter]) async throws {
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            ModelMapping.databaseValue(book.id),
            .string(book.title),
            .string(ModelMapping.authorsJSON(book.authors)),
            ModelMapping.databaseValue(book.summary),
            ModelMapping.databaseValue(book.sourceID),
            ModelMapping.databaseValue(book.coverURL),
            ModelMapping.databaseValue(book.createdAt),
            ModelMapping.databaseValue(book.updatedAt),
            .bool(book.isFavorite)
        ])

        for chapter in chapters {
            try await database.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                ModelMapping.databaseValue(chapter.id),
                ModelMapping.databaseValue(chapter.bookID),
                .string(chapter.title),
                .string(chapter.sortKey),
                .int(Int64(chapter.index)),
                ModelMapping.databaseValue(chapter.duration),
                ModelMapping.databaseValue(chapter.remoteURL),
                ModelMapping.databaseValue(chapter.localURL)
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
            localURL: ModelMapping.url(row, "local_url")
        )
    }
}
