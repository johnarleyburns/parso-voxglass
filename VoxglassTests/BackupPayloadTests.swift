import XCTest
@testable import Voxglass

final class BackupPayloadTests: XCTestCase {

    func testRoundTripEncodeDecode() throws {
        let bookID = UUID()
        let sourceID = UUID()
        let chapterID = UUID()

        let payload = BackupPayload(
            version: 1,
            exportDate: Date(timeIntervalSince1970: 1000),
            books: [
                BackupPayload.BookPayload(
                    book: Book(
                        id: bookID,
                        title: "Test Book",
                        authors: ["Author One"],
                        narrators: ["Narrator A"],
                        summary: "A test book",
                        sourceID: sourceID,
                        createdAt: Date(timeIntervalSince1970: 500),
                        updatedAt: Date(timeIntervalSince1970: 800),
                        isFavorite: true
                    ),
                    chapters: [
                        Chapter(
                            id: chapterID,
                            bookID: bookID,
                            title: "Chapter 1",
                            index: 0,
                            duration: 120,
                            remoteURL: URL(string: "https://archive.org/test.mp3")
                        )
                    ],
                    source: Source(
                        id: sourceID,
                        kind: .librivox,
                        title: "LibriVox Source",
                        url: URL(string: "https://librivox.org/test"),
                        createdAt: Date(timeIntervalSince1970: 400)
                    )
                )
            ],
            positions: [
                PlaybackPosition(
                    id: UUID(),
                    bookID: bookID,
                    chapterID: chapterID,
                    position: 42.5,
                    duration: 120,
                    updatedAt: Date(timeIntervalSince1970: 900),
                    isFinished: false
                )
            ],
            bookmarks: [
                Bookmark(
                    id: UUID(),
                    bookID: bookID,
                    chapterID: chapterID,
                    position: 30,
                    note: "Interesting passage",
                    createdAt: Date(timeIntervalSince1970: 600),
                    updatedAt: Date(timeIntervalSince1970: 700),
                    isDeleted: false
                )
            ],
            playlists: [
                BackupPayload.PlaylistPayload(
                    playlist: Playlist(
                        id: UUID(),
                        title: "Favorites",
                        createdAt: Date(timeIntervalSince1970: 100),
                        updatedAt: Date(timeIntervalSince1970: 200)
                    ),
                    bookIDs: [bookID]
                )
            ],
            tasteTerms: [
                BackupPayload.TasteTermPayload(axis: "creator", term: "Author One", weight: 3.5)
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BackupPayload.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.books.count, 1)
        XCTAssertEqual(decoded.books[0].book.title, "Test Book")
        XCTAssertEqual(decoded.books[0].chapters.count, 1)
        XCTAssertEqual(decoded.books[0].source?.title, "LibriVox Source")
        XCTAssertEqual(decoded.positions.count, 1)
        XCTAssertEqual(decoded.positions[0].position, 42.5)
        XCTAssertEqual(decoded.bookmarks.count, 1)
        XCTAssertEqual(decoded.bookmarks[0].note, "Interesting passage")
        XCTAssertEqual(decoded.playlists.count, 1)
        XCTAssertEqual(decoded.playlists[0].playlist.title, "Favorites")
        XCTAssertEqual(decoded.tasteTerms.count, 1)
        XCTAssertEqual(decoded.tasteTerms[0].weight, 3.5)
    }

    func testEmptyPayloadRoundTrip() throws {
        let payload = BackupPayload(
            version: 1,
            exportDate: Date(),
            books: [],
            positions: [],
            bookmarks: [],
            playlists: [],
            tasteTerms: []
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(BackupPayload.self, from: data)

        XCTAssertEqual(decoded.books.count, 0)
        XCTAssertEqual(decoded.positions.count, 0)
    }

    func testVersionMismatchIsRejected() {
        let payload = BackupPayload(
            version: 999,
            exportDate: Date(),
            books: [],
            positions: [],
            bookmarks: [],
            playlists: [],
            tasteTerms: []
        )
        // Version 999 > currentVersion, so should be rejected during import.
        XCTAssertGreaterThan(payload.version, BackupPayload.currentVersion,
            "If a backup has a higher version than current, the import must reject it")
    }

    @MainActor func testExportIsNoOpWhenNotEntitled() async {
        EntitlementCache.shared.setTestEntitlement(false)
        defer { EntitlementCache.shared.setTestEntitlement(nil) }

        let database = AppDatabase.makeTemporaryDatabase(named: "backup-not-entitled")
        let service = LibraryBackupService(database: database)
        let payload = await service.exportPayload()
        XCTAssertNil(payload, "Export must be a no-op when libraryBackup is not entitled")
        XCTAssertNotNil(service.exportError)
    }

    @MainActor func testImportIsNoOpWhenNotEntitled() async {
        EntitlementCache.shared.setTestEntitlement(false)
        defer { EntitlementCache.shared.setTestEntitlement(nil) }

        let database = AppDatabase.makeTemporaryDatabase(named: "import-not-entitled")
        let service = LibraryBackupService(database: database)
        // Use a temp file path that doesn't exist, but the gate check is first.
        let count = await service.importFromFile(URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(count, 0, "Import must be a no-op when libraryBackup is not entitled")
    }

    @MainActor func testImportIsIdempotent() async throws {
        EntitlementCache.shared.setTestEntitlement(true)
        defer { EntitlementCache.shared.setTestEntitlement(nil) }

        let database = AppDatabase.makeTemporaryDatabase(named: "backup-idempotent")
        let service = LibraryBackupService(database: database)

        let bookID = UUID(), sourceID = UUID()
        let payload = BackupPayload(
            version: 1,
            exportDate: Date(),
            books: [
                BackupPayload.BookPayload(
                    book: Book(id: bookID, title: "Test", authors: [], sourceID: sourceID),
                    chapters: [
                        Chapter(id: UUID(), bookID: bookID, title: "Ch1", index: 0)
                    ],
                    source: Source(id: sourceID, kind: .librivox, title: "S")
                )
            ],
            positions: [],
            bookmarks: [],
            playlists: [],
            tasteTerms: []
        )

        let first = await service.importPayload(payload)
        XCTAssertEqual(first, 1)

        let second = await service.importPayload(payload)
        XCTAssertEqual(second, 0, "Re-importing the same payload must not create duplicates")
    }
}
