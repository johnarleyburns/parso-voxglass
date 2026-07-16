import XCTest
@testable import VoxglassCore

final class NarratorMatcherTests: XCTestCase {

    func testStemJoinMatchesMultiReaderChapters() throws {
        let chapters: [Chapter] = [
            Chapter(id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
                    remoteURL: URL(string: "https://archive.org/download/test_identifier_4489/shortsf045_01_various_128kb.mp3")),
            Chapter(id: UUID(), bookID: UUID(), title: "Chapter 2", index: 1,
                    remoteURL: URL(string: "https://archive.org/download/test_identifier_4489/shortsf045_02_various_128kb.mp3")),
            Chapter(id: UUID(), bookID: UUID(), title: "Chapter 3", index: 2,
                    remoteURL: URL(string: "https://archive.org/download/test_identifier_4489/shortsf045_03_various_128kb.mp3"))
        ]

        let sections: [LibriVoxSection] = [
            section(fileName: "shortsf045_01_various_128kb.mp3", sectionNumber: "01",
                    readers: [reader("Mike Harris")], urlIArchive: "https://archive.org/details/test_identifier_4489"),
            section(fileName: "shortsf045_02_various_128kb.mp3", sectionNumber: "02",
                    readers: [reader("Don W. Jenkins")], urlIArchive: "https://archive.org/details/test_identifier_4489"),
            section(fileName: "shortsf045_03_various_128kb.mp3", sectionNumber: "03",
                    readers: [reader("Gregg Margarite")], urlIArchive: "https://archive.org/details/test_identifier_4489")
        ]

        let result = NarratorMatcher.match(chapters: chapters, sections: sections, archiveIdentifier: "test_identifier_4489")

        XCTAssertEqual(result[chapters[0].id], ["Mike Harris"])
        XCTAssertEqual(result[chapters[1].id], ["Don W. Jenkins"])
        XCTAssertEqual(result[chapters[2].id], ["Gregg Margarite"])
    }

    func testRejectsResponseWhoseIArchiveURLDoesNotMatchIdentifier() {
        let chapters: [Chapter] = [
            Chapter(id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
                    remoteURL: URL(string: "https://archive.org/download/test_identifier/good_chapter.mp3"))
        ]

        let sections: [LibriVoxSection] = [
            section(fileName: "good_chapter.mp3", sectionNumber: "1",
                    readers: [reader("Wrong Narrator")],
                    urlIArchive: "https://archive.org/details/wrong_identifier"),
            section(fileName: "good_chapter.mp3", sectionNumber: "1",
                    readers: [reader("Correct Narrator")],
                    urlIArchive: "https://archive.org/details/test_identifier")
        ]

        let result = NarratorMatcher.match(chapters: chapters, sections: sections, archiveIdentifier: "test_identifier")

        XCTAssertEqual(result[chapters[0].id], ["Correct Narrator"],
                       "Should match only the section whose url_iarchive matches the identifier")
    }

    func testNullFileNameFallsBackToListenURL() {
        let chapters: [Chapter] = [
            Chapter(id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
                    remoteURL: URL(string: "https://archive.org/download/test_identifier/old_book_chapter_1.mp3"))
        ]

        let sections: [LibriVoxSection] = [
            LibriVoxSection(
                sectionNumber: "1",
                listenURL: "https://archive.org/download/test_identifier/old_book_chapter_1.mp3",
                fileName: nil,
                readers: [reader("Old Reader")],
                urlIArchive: "https://archive.org/details/test_identifier"
            )
        ]

        let result = NarratorMatcher.match(chapters: chapters, sections: sections, archiveIdentifier: "test_identifier")

        XCTAssertEqual(result[chapters[0].id], ["Old Reader"])
    }

    func testStemJoinStrips64kbAnd128kbSuffixes() {
        let chapters: [Chapter] = [
            Chapter(id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
                    remoteURL: URL(string: "https://archive.org/download/test_identifier/chapter001_128kb.mp3"))
        ]

        let sections: [LibriVoxSection] = [
            section(fileName: "chapter001_64kb.mp3", sectionNumber: "1",
                    readers: [reader("A Reader")], urlIArchive: "https://archive.org/details/test_identifier")
        ]

        let result = NarratorMatcher.match(chapters: chapters, sections: sections, archiveIdentifier: "test_identifier")

        XCTAssertEqual(result[chapters[0].id], ["A Reader"],
                       "Should match despite different quality suffixes")
    }

    func testBookLevelNarratorsCollectsUnique() {
        let sections: [LibriVoxSection] = [
            section(fileName: "ch1.mp3", sectionNumber: "1",
                    readers: [reader("Alice"), reader("Bob")], urlIArchive: "https://archive.org/details/test"),
            section(fileName: "ch2.mp3", sectionNumber: "2",
                    readers: [reader("Alice"), reader("Charlie")], urlIArchive: "https://archive.org/details/test")
        ]

        let narrators = NarratorMatcher.bookLevelNarrators(from: sections)

        XCTAssertEqual(narrators, ["Alice", "Bob", "Charlie"])
    }

    func testEmptyInputsReturnEmpty() {
        let chapters: [Chapter] = []
        let sections: [LibriVoxSection] = []

        let result = NarratorMatcher.match(chapters: chapters, sections: sections, archiveIdentifier: "test")

        XCTAssertTrue(result.isEmpty)
    }

    func testSectionMatchesArchiveHandlesURLVariations() {
        XCTAssertTrue(NarratorMatcher.sectionMatchesArchive(
            section: section(fileName: "x.mp3", sectionNumber: "1", readers: [], urlIArchive: "https://archive.org/details/my_book"),
            identifier: "my_book"
        ))
        XCTAssertTrue(NarratorMatcher.sectionMatchesArchive(
            section: section(fileName: "x.mp3", sectionNumber: "1", readers: [], urlIArchive: "https://archive.org/details/my_book/"),
            identifier: "my_book"
        ))
        XCTAssertFalse(NarratorMatcher.sectionMatchesArchive(
            section: section(fileName: "x.mp3", sectionNumber: "1", readers: [], urlIArchive: nil),
            identifier: "my_book"
        ))
    }

    // MARK: - Helpers

    private func reader(_ name: String) -> LibriVoxReader {
        LibriVoxReader(readerID: nil, displayName: name)
    }

    private func section(fileName: String, sectionNumber: String, readers: [LibriVoxReader], urlIArchive: String?) -> LibriVoxSection {
        LibriVoxSection(
            sectionNumber: sectionNumber,
            listenURL: nil,
            fileName: fileName,
            readers: readers,
            urlIArchive: urlIArchive
        )
    }
}
