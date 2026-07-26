import Testing
import Foundation
@testable import VoxglassCore

/// Phase 3 — deterministic identity. Pure, no I/O.
@Suite struct ContentKeyTests {

    @Test func bookContentKeyIsStableAcrossReimport() {
        let first = ContentKey.book(
            forSourceURL: URL(string: "https://archive.org/details/pride_and_prejudice_librivox"),
            kind: .librivox
        )
        let second = ContentKey.book(
            forSourceURL: URL(string: "https://archive.org/details/pride_and_prejudice_librivox"),
            kind: .internetArchive
        )
        #expect(first == "ia:pride_and_prejudice_librivox")
        #expect(first == second)  // The same IA item must produce the same key on every import
        #expect(first == ContentKey.book(forInternetArchiveIdentifier: "pride_and_prejudice_librivox"))
    }

    @Test func bookContentKeyForLocalFolder() {
        let url = URL(fileURLWithPath: "/Users/me/Audiobooks/My Great Book")
        #expect(ContentKey.book(forSourceURL: url, kind: .localFiles) == "local:my-great-book")
        #expect(ContentKey.book(forLocalFolderName: "My Great Book") == "local:my-great-book")
        #expect(ContentKey.book(forLocalFolderName: "My Great Book") == ContentKey.book(forSourceURL: URL(fileURLWithPath: "/Volumes/External/My Great Book"), kind: .localFiles))  // A folder move must not change the key
    }

    @Test func bookContentKeyIsNilWithoutStableIdentity() {
        #expect(ContentKey.book(forSourceURL: nil, kind: .librivox) == nil)
        #expect(ContentKey.book(forSourceURL: URL(string: "https://archive.org/"), kind: .librivox) == nil)
        #expect(ContentKey.book(forInternetArchiveIdentifier: "") == nil)
    }

    @Test func chapterContentKeyUsesFilenameStem() {
        let remote = ContentKey.chapter(
            remoteURL: URL(string: "https://archive.org/download/item/prideandprejudice_01_austen_64kb.mp3"),
            localURL: nil, index: 0, title: "Chapter 1"
        )
        #expect(remote == "prideandprejudice-01-austen-64kb")

        let local = ContentKey.chapter(
            remoteURL: nil,
            localURL: URL(fileURLWithPath: "/Volumes/External/Book/PrideAndPrejudice_01_Austen_64kb.MP3"),
            index: 0, title: "Chapter 1"
        )
        #expect(local == remote)  // The same file must key identically whether remote or local, wherever it lives
    }

    @Test func chapterContentKeyFallsBackToTitleThenIndex() {
        #expect(ContentKey.chapter(remoteURL: nil, localURL: nil, index: 3, title: "Chapter 4 — The Ball") == "chapter-4-the-ball")
        #expect(ContentKey.chapter(remoteURL: nil, localURL: nil, index: 3, title: "———") == "idx:3")
    }

    @Test func normalizeFoldsCaseDiacriticsAndPunctuation() {
        #expect(ContentKey.normalize("Chapter 01 — L'Étranger") == "chapter-01-l-etranger")
        #expect(ContentKey.normalize("chapter_01__l_etranger") == "chapter-01-l-etranger")
    }
}
