import XCTest
@testable import VoxglassCore

/// Phase 3 — deterministic identity. Pure, no I/O.
final class ContentKeyTests: XCTestCase {

    func testBookContentKeyIsStableAcrossReimport() {
        let first = ContentKey.book(
            forSourceURL: URL(string: "https://archive.org/details/pride_and_prejudice_librivox"),
            kind: .librivox
        )
        let second = ContentKey.book(
            forSourceURL: URL(string: "https://archive.org/details/pride_and_prejudice_librivox"),
            kind: .internetArchive
        )
        XCTAssertEqual(first, "ia:pride_and_prejudice_librivox")
        XCTAssertEqual(first, second, "The same IA item must produce the same key on every import")
        XCTAssertEqual(first, ContentKey.book(forInternetArchiveIdentifier: "pride_and_prejudice_librivox"))
    }

    func testBookContentKeyForLocalFolder() {
        let url = URL(fileURLWithPath: "/Users/me/Audiobooks/My Great Book")
        XCTAssertEqual(ContentKey.book(forSourceURL: url, kind: .localFiles), "local:my-great-book")
        XCTAssertEqual(ContentKey.book(forLocalFolderName: "My Great Book"), "local:my-great-book")
        XCTAssertEqual(
            ContentKey.book(forLocalFolderName: "My Great Book"),
            ContentKey.book(forSourceURL: URL(fileURLWithPath: "/Volumes/External/My Great Book"), kind: .localFiles),
            "A folder move must not change the key"
        )
    }

    func testBookContentKeyIsNilWithoutStableIdentity() {
        XCTAssertNil(ContentKey.book(forSourceURL: nil, kind: .librivox))
        XCTAssertNil(ContentKey.book(forSourceURL: URL(string: "https://archive.org/"), kind: .librivox))
        XCTAssertNil(ContentKey.book(forInternetArchiveIdentifier: ""))
    }

    func testChapterContentKeyUsesFilenameStem() {
        let remote = ContentKey.chapter(
            remoteURL: URL(string: "https://archive.org/download/item/prideandprejudice_01_austen_64kb.mp3"),
            localURL: nil, index: 0, title: "Chapter 1"
        )
        XCTAssertEqual(remote, "prideandprejudice-01-austen-64kb")

        let local = ContentKey.chapter(
            remoteURL: nil,
            localURL: URL(fileURLWithPath: "/Volumes/External/Book/PrideAndPrejudice_01_Austen_64kb.MP3"),
            index: 0, title: "Chapter 1"
        )
        XCTAssertEqual(local, remote, "The same file must key identically whether remote or local, wherever it lives")
    }

    func testChapterContentKeyFallsBackToTitleThenIndex() {
        XCTAssertEqual(
            ContentKey.chapter(remoteURL: nil, localURL: nil, index: 3, title: "Chapter 4 — The Ball"),
            "chapter-4-the-ball"
        )
        XCTAssertEqual(
            ContentKey.chapter(remoteURL: nil, localURL: nil, index: 3, title: "———"),
            "idx:3"
        )
    }

    func testNormalizeFoldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(ContentKey.normalize("Chapter 01 — L'Étranger"), "chapter-01-l-etranger")
        XCTAssertEqual(ContentKey.normalize("chapter_01__l_etranger"), "chapter-01-l-etranger")
    }
}
