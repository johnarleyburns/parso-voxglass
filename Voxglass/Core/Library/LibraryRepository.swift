import Foundation

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

