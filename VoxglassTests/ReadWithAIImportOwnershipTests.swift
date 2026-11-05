import Foundation
import Testing
@testable import VoxglassCore

@Suite
struct ReadWithAIImportOwnershipTests {
    @Test func localReadWithAIImportIsImmediatelyVisibleInMyBooks() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "read-ai-owned-\(UUID())")
        let repository = LibraryRepository(database: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("chapter.voxtext")
        try "A readable local PDF chapter.".write(to: textURL, atomically: true, encoding: .utf8)

        let text = "A readable local PDF chapter."
        let book = try await repository.importReadWithAI(ReadWithAIImport(
            title: "Local opinion", authors: [], sourceTitle: "Files",
            chapters: [ReadWithAIChapterImport(title: "Page 1", textURL: textURL)]
        ))

        #expect(!book.book.isPending)
        #expect(book.chapters.first?.duration == ReadWithAIDurationEstimate.duration(for: text))
        let library = try await repository.fetchLibrary()
        #expect(library.first(where: { $0.book.id == book.book.id })?.book.isPending == false)
    }

    @Test func migrationRestoresHiddenLocalReadWithAIImportsOnly() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "read-ai-repair-\(UUID())")
        try await database.prepare()
        let localSource = UUID()
        let remoteSource = UUID()
        let localBook = UUID()
        let remoteBook = UUID()
        for source in [(localSource, DatabaseValue.null), (remoteSource, DatabaseValue.string("https://www.gutenberg.org/ebooks/84"))] {
            try await database.execute(
                "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, 'readWithAI', 'Read with AI', ?, 0)",
                [.string(source.0.uuidString), source.1]
            )
        }
        for book in [(localBook, localSource), (remoteBook, remoteSource)] {
            try await database.execute(
                "INSERT INTO books (id, title, authors_json, source_id, created_at, updated_at, is_favorite, is_pending) VALUES (?, 'Book', '[]', ?, 0, 0, 0, 1)",
                [.string(book.0.uuidString), .string(book.1.uuidString)]
            )
        }
        try await database.execute("DELETE FROM schema_migrations WHERE id = 17", [])
        try await database.migrate()

        let rows = try await database.query("SELECT id, is_pending FROM books ORDER BY id", [])
        let pendingByID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.string("id").map { ($0, row.bool("is_pending") ?? true) }
        })
        #expect(pendingByID[localBook.uuidString] == false)
        #expect(pendingByID[remoteBook.uuidString] == true)
    }
}
