import Testing
import Foundation
@testable import VoxglassCore

@Suite struct NarratorMatcherTests {

    @Test func stemJoinMatchesMultiReaderChapters() throws {
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

        #expect(result[chapters[0].id] == ["Mike Harris"])
        #expect(result[chapters[1].id] == ["Don W. Jenkins"])
        #expect(result[chapters[2].id] == ["Gregg Margarite"])
    }

    @Test func rejectsResponseWhoseIArchiveURLDoesNotMatchIdentifier() {
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

        #expect(result[chapters[0].id] == ["Correct Narrator"])  // Should match only the section whose url_iarchive matches the identifier
    }

    @Test func nullFileNameFallsBackToListenURL() {
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

        #expect(result[chapters[0].id] == ["Old Reader"])
    }

    @Test func stemJoinStrips64kbAnd128kbSuffixes() {
        let chapters: [Chapter] = [
            Chapter(id: UUID(), bookID: UUID(), title: "Chapter 1", index: 0,
                    remoteURL: URL(string: "https://archive.org/download/test_identifier/chapter001_128kb.mp3"))
        ]

        let sections: [LibriVoxSection] = [
            section(fileName: "chapter001_64kb.mp3", sectionNumber: "1",
                    readers: [reader("A Reader")], urlIArchive: "https://archive.org/details/test_identifier")
        ]

        let result = NarratorMatcher.match(chapters: chapters, sections: sections, archiveIdentifier: "test_identifier")

        #expect(result[chapters[0].id] == ["A Reader"])  // Should match despite different quality suffixes
    }

    @Test func bookLevelNarratorsCollectsUnique() {
        let sections: [LibriVoxSection] = [
            section(fileName: "ch1.mp3", sectionNumber: "1",
                    readers: [reader("Alice"), reader("Bob")], urlIArchive: "https://archive.org/details/test"),
            section(fileName: "ch2.mp3", sectionNumber: "2",
                    readers: [reader("Alice"), reader("Charlie")], urlIArchive: "https://archive.org/details/test")
        ]

        let narrators = NarratorMatcher.bookLevelNarrators(from: sections)

        #expect(narrators == ["Alice", "Bob", "Charlie"])
    }

    @Test func emptyInputsReturnEmpty() {
        let chapters: [Chapter] = []
        let sections: [LibriVoxSection] = []

        let result = NarratorMatcher.match(chapters: chapters, sections: sections, archiveIdentifier: "test")

        #expect(result.isEmpty)
    }

    @Test func sectionMatchesArchiveHandlesURLVariations() {
        #expect(NarratorMatcher.sectionMatchesArchive(
            section: section(fileName: "x.mp3", sectionNumber: "1", readers: [], urlIArchive: "https://archive.org/details/my_book"),
            identifier: "my_book"
        ))
        #expect(NarratorMatcher.sectionMatchesArchive(
            section: section(fileName: "x.mp3", sectionNumber: "1", readers: [], urlIArchive: "https://archive.org/details/my_book/"),
            identifier: "my_book"
        ))
        #expect(!(NarratorMatcher.sectionMatchesArchive(
            section: section(fileName: "x.mp3", sectionNumber: "1", readers: [], urlIArchive: nil),
            identifier: "my_book"
        )))
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
