import XCTest
@testable import Voxglass

final class InternetArchiveCatalogTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testAdvancedSearchFixtureDecodesLibriVoxResults() throws {
        let data = try fixtureData("advanced_search_librivox")
        let response = try decoder.decode(InternetArchiveSearchResponse.self, from: data)

        XCTAssertEqual(response.results.count, 2)
        XCTAssertEqual(response.results[0].identifier, "pride_and_prejudice_librivox")
        XCTAssertEqual(response.results[0].title, "Pride and Prejudice")
        XCTAssertEqual(response.results[0].authorLine, "Jane Austen")
        XCTAssertEqual(response.results[0].sourceKind, .librivox)
        XCTAssertEqual(response.results[1].creators, ["Various"])
        XCTAssertEqual(response.results[1].downloads, 678)
    }

    func testMetadataFixtureDeduplicatesAudioDerivativesByQuality() throws {
        let metadata = try metadataFixture()
        let selected = metadata.selectedAudioFiles

        XCTAssertEqual(selected.map(\.name), [
            "01 Chapter One.mp3",
            "02 Chapter Two_vbr.mp3",
            "10 Chapter Ten_64kb.mp3"
        ])
    }

    func testMetadataFixtureBuildsNaturalChapterOrderAndDurations() throws {
        let metadata = try metadataFixture()
        let chapters = metadata.selectedAudioFiles.enumerated().compactMap { index, file -> Chapter? in
            guard let remoteURL = metadata.fileURL(for: file) else { return nil }
            return Chapter(
                bookID: UUID(),
                title: InternetArchiveAudioSelector.chapterTitle(for: file),
                sortKey: file.track ?? file.name,
                index: index,
                duration: file.duration,
                remoteURL: remoteURL
            )
        }

        XCTAssertEqual(chapters.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 10"])
        XCTAssertEqual(chapters.map(\.duration), [100, 200, 600])
        XCTAssertEqual(chapters[0].remoteURL?.absoluteString, "https://archive.org/download/pride_and_prejudice_librivox/01%20Chapter%20One.mp3")
    }

    func testArchiveURLParserRecognizesItemMetadataDownloadAndSearchURLs() {
        XCTAssertEqual(
            InternetArchiveURLParser.parse("https://archive.org/details/pride_and_prejudice_librivox"),
            .identifier("pride_and_prejudice_librivox")
        )
        XCTAssertEqual(
            InternetArchiveURLParser.parse("archive.org/metadata/pride_and_prejudice_librivox"),
            .identifier("pride_and_prejudice_librivox")
        )
        XCTAssertEqual(
            InternetArchiveURLParser.parse("https://archive.org/download/pride_and_prejudice_librivox/01%20Chapter%20One.mp3"),
            .identifier("pride_and_prejudice_librivox")
        )
        XCTAssertEqual(
            InternetArchiveURLParser.parse("https://archive.org/advancedsearch.php?q=collection%3A%28librivoxaudio%29"),
            .advancedSearch(query: "collection:(librivoxaudio)")
        )
    }

    func testLibriVoxBrowseCategoriesUseSemanticArchiveQueries() {
        let categories = LibriVoxBrowseGroup.categories
        let ids = Set(categories.map(\.id))

        XCTAssertEqual(categories.count, 21)
        XCTAssertEqual(ids.count, categories.count)
        XCTAssertEqual(LibriVoxBrowseGroup.all.map(\.title), ["Fiction", "Forms", "Ideas & Nonfiction"])
        XCTAssertTrue(categories.allSatisfy { $0.archiveQuery.contains("collection:librivoxaudio") })
        XCTAssertTrue(categories.allSatisfy { !$0.archiveQuery.contains("http://") && !$0.archiveQuery.contains("https://") })
        XCTAssertTrue(LibriVoxBrowseCategory.scienceFiction.archiveQuery.contains("subject:\"Science Fiction\""))
        XCTAssertTrue(LibriVoxBrowseCategory.philosophyMind.archiveQuery.contains("AND NOT"))
    }

    func testInternetArchiveImportRoundTripsAndDeduplicatesInDatabase() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "internet-archive-import")
        let repository = LibraryRepository(database: database)
        let metadata = try metadataFixture()

        let first = try await repository.importInternetArchiveItem(metadata, sourceKind: .librivox)
        let second = try await repository.importInternetArchiveItem(metadata, sourceKind: .librivox)
        let library = try await repository.fetchLibrary()

        XCTAssertEqual(first.book.id, second.book.id)
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library[0].book.title, "Pride and Prejudice")
        XCTAssertEqual(library[0].book.authors, ["Jane Austen"])
        XCTAssertEqual(library[0].chapters.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 10"])
        XCTAssertEqual(library[0].book.summary, "LibriVox recording & public-domain audiobook.")
    }

    private func metadataFixture() throws -> InternetArchiveMetadata {
        let data = try fixtureData("metadata_librivox_item")
        return try decoder.decode(InternetArchiveMetadata.self, from: data)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("InternetArchive", isDirectory: true)
            .appendingPathComponent("\(name).json")
        return try Data(contentsOf: fixtureURL)
    }
}
