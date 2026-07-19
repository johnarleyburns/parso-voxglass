import XCTest
@testable import VoxglassCore

@MainActor
final class LibraryBackupExportTests: XCTestCase {

    func testExportToFileProducesNonEmptyFile() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "backup-export-nonempty")
        try await database.prepare()

        let sourceID = UUID()
        try await database.execute("""
        INSERT INTO sources (id, kind, title, url, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [
            .string(sourceID.uuidString),
            .string(SourceKind.librivox.rawValue),
            .string("Test Source"),
            .string("https://librivox.org/test"),
            .double(Date().timeIntervalSince1970)
        ])

        let bookID = UUID()
        let now = Date().timeIntervalSince1970
        try await database.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString),
            .string("Test Book"),
            .string("[\"Test Author\"]"),
            .string("A test book"),
            .string(sourceID.uuidString),
            .null,
            .double(now),
            .double(now),
            .bool(false)
        ])

        let chapterID = UUID()
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
            .string("https://archive.org/test.mp3"),
            .null
        ])

        let posID = UUID()
        try await database.execute("""
        INSERT INTO playback_positions (id, book_id, chapter_id, position_seconds, duration_seconds, updated_at, is_finished)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(posID.uuidString),
            .string(bookID.uuidString),
            .string(chapterID.uuidString),
            .double(42.5),
            .double(120),
            .double(now),
            .bool(false)
        ])

        let bmID = UUID()
        try await database.execute("""
        INSERT INTO bookmarks (id, book_id, chapter_id, position_seconds, note, created_at, updated_at, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bmID.uuidString),
            .string(bookID.uuidString),
            .string(chapterID.uuidString),
            .double(30),
            .string("Note"),
            .double(now),
            .double(now),
            .bool(false)
        ])

        let service = LibraryBackupService(database: database)

        guard let url = await service.exportToFile() else {
            XCTFail("exportToFile() returned nil")
            return
        }

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: url.path), "Exported file must exist")
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 0, "Exported file must be non-empty (\(size) bytes)")

        // Import into a fresh database to verify round-trip.
        let freshDB = AppDatabase.makeTemporaryDatabase(named: "backup-import-fresh")
        try await freshDB.prepare()
        let importService = LibraryBackupService(database: freshDB)
        let importCount = await importService.importFromFile(url)
        XCTAssertEqual(importCount, 1, "Round-trip import must restore the book")

        let importedPayload = await importService.exportPayload()
        XCTAssertNotNil(importedPayload)
        XCTAssertEqual(importedPayload?.books.count, 1)
        XCTAssertEqual(importedPayload?.books.first?.book.title, "Test Book")
        XCTAssertEqual(importedPayload?.positions.count, 1)
        XCTAssertEqual(importedPayload?.bookmarks.count, 1)

        let payload = await service.exportPayload()
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.books.count, 1)
        XCTAssertEqual(payload?.books.first?.book.title, "Test Book")
        XCTAssertEqual(payload?.positions.count, 1)
        XCTAssertEqual(payload?.bookmarks.count, 1)
    }

    func testExportEmptyLibraryProducesEmptyPayload() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "backup-export-empty")
        try await database.prepare()

        let service = LibraryBackupService(database: database)
        let payload = await service.exportPayload()
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.books.count, 0)
        XCTAssertEqual(payload?.positions.count, 0)
    }
}
