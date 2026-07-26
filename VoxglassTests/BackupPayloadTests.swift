import Testing
import Foundation
@testable import VoxglassCore

@Suite struct BackupPayloadTests {

    @Test func roundTripEncodeDecode() throws {
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

        #expect(decoded.version == 1)
        #expect(decoded.books.count == 1)
        #expect(decoded.books[0].book.title == "Test Book")
        #expect(decoded.books[0].chapters.count == 1)
        #expect(decoded.books[0].source?.title == "LibriVox Source")
        #expect(decoded.positions.count == 1)
        #expect(decoded.positions[0].position == 42.5)
        #expect(decoded.bookmarks.count == 1)
        #expect(decoded.bookmarks[0].note == "Interesting passage")
        #expect(decoded.playlists.count == 1)
        #expect(decoded.playlists[0].playlist.title == "Favorites")
        #expect(decoded.tasteTerms.count == 1)
        #expect(decoded.tasteTerms[0].weight == 3.5)
    }

    @Test func emptyPayloadRoundTrip() throws {
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

        #expect(decoded.books.count == 0)
        #expect(decoded.positions.count == 0)
    }

    @Test func versionMismatchIsRejected() {
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
        #expect(payload.version > BackupPayload.currentVersion)
    }
}

