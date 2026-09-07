import Testing
import Foundation
@testable import VoxglassWatchCore
@testable import VoxglassCore

/// A single-file, multi-chapter local import shares one `localURL` across
/// every chapter. `PhoneWatchProjection.book(from:)` used to hash that file
/// with `WatchChecksum.sha256` once *per chapter*, unmemoized — for a real
/// 1.2GB local import with 42 chapters, that meant hashing the same 1.2GB
/// file 42+ times in a row, synchronously, on every Watch snapshot rebuild
/// (including on chapter navigation), which blew past the device's memory
/// limit and got the app killed. This suite locks the fix: each distinct
/// file is hashed once, and every chapter that shares it still gets the
/// correct hash.
@Suite struct PhoneWatchProjectionHashCacheTests {

    private func makeSharedAssetBook(fileURL: URL, chapterCount: Int) -> BookWithChapters {
        let bookID = UUID()
        let chapters = (0..<chapterCount).map { index in
            Chapter(
                bookID: bookID,
                title: "Chapter \(index)",
                index: index,
                startTime: TimeInterval(index * 100),
                duration: 100,
                localURL: fileURL
            )
        }
        return BookWithChapters(
            book: Book(id: bookID, title: "Shared Asset Book", authors: ["Author"], sourceID: UUID()),
            chapters: chapters
        )
    }

    @Test func everyChapterSharingOneFileGetsTheSameCorrectHash() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-watch-projection-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(repeating: 0x5A, count: 4096).write(to: fileURL)
        let expectedHash = try WatchChecksum.sha256(of: fileURL)

        let book = makeSharedAssetBook(fileURL: fileURL, chapterCount: 12)
        let dto = PhoneWatchProjection.book(from: book)

        #expect(dto.chapters.count == 12)
        for chapter in dto.chapters {
            #expect(chapter.expectedSHA256 == expectedHash)
        }
    }

    @Test func chaptersWithNoLocalFileGetNoHash() {
        let bookID = UUID()
        let chapter = Chapter(bookID: bookID, title: "Remote", index: 0, duration: 100, remoteURL: URL(string: "https://example.com/a.mp3")!)
        let book = BookWithChapters(
            book: Book(id: bookID, title: "Remote Book", authors: ["Author"], sourceID: UUID()),
            chapters: [chapter]
        )

        let dto = PhoneWatchProjection.book(from: book)

        #expect(dto.chapters.first?.expectedSHA256 == nil)
        #expect(dto.chapters.first?.expectedBytes == nil)
    }
}
