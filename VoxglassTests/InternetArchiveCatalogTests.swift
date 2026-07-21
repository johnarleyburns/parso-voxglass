import XCTest
@testable import VoxglassCore

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

        XCTAssertEqual(categories.count, 20)
        XCTAssertEqual(ids.count, categories.count)
        XCTAssertEqual(LibriVoxBrowseGroup.all.map(\.title), ["Fiction", "Forms", "Ideas & Nonfiction"])
        XCTAssertTrue(categories.allSatisfy { $0.archiveQuery.contains(LibriVoxCatalogScope.collectionClause) })
        XCTAssertTrue(categories.allSatisfy { !$0.archiveQuery.contains("audio_bookspoetry") })
        XCTAssertTrue(categories.allSatisfy { $0.archiveQuery.contains("mediatype:audio") })
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

    func testLibriVoxQueryBuilderScopesToLibriVoxWithBoostsAndPhraseClause() {
        let query = InternetArchiveClient.libriVoxQuery(for: "sherlock holmes")

        XCTAssertTrue(query.contains(LibriVoxCatalogScope.query))
        // Whole-phrase boost clause across title/subject/description.
        XCTAssertTrue(query.contains("title:\"sherlock holmes\"^8"))
        XCTAssertTrue(query.contains("subject:\"sherlock holmes\"^6"))
        XCTAssertTrue(query.contains("description:\"sherlock holmes\"^4"))
        // Per-token clause now includes subject + description fields.
        XCTAssertTrue(query.contains("title:\"sherlock\"^4"))
        XCTAssertTrue(query.contains("creator:\"sherlock\"^3"))
        XCTAssertTrue(query.contains("subject:\"holmes\"^2"))
        XCTAssertTrue(query.contains("description:\"holmes\"^1"))
        XCTAssertTrue(query.contains("collection:librivoxaudio"))
        XCTAssertFalse(query.contains("audio_bookspoetry"))
        XCTAssertTrue(query.contains(") OR ("))
    }

    func testLibriVoxQueryBuilderHandlesEmptyInput() {
        let query = InternetArchiveClient.libriVoxQuery(for: "   ")
        XCTAssertEqual(query, LibriVoxCatalogScope.query)
    }

    func testLibriVoxQueryBuilderAllowsSubjectAnchoredThematicSearch() {
        // Regression for §8: "greek plays" must be satisfiable via subject/
        // description (no mandatory title/creator-only anchor).
        let query = InternetArchiveClient.libriVoxQuery(for: "greek plays")

        XCTAssertTrue(query.contains("subject:\"greek\"^2"))
        XCTAssertTrue(query.contains("subject:\"plays\"^2"))
        XCTAssertTrue(query.contains("title:\"greek plays\"^8"))
        // No bare (unboosted) title/creator-only mandatory clause remains.
        XCTAssertFalse(query.contains("title:\"greek\" OR creator:\"greek\""))
        XCTAssertFalse(query.contains("title:\"plays\" OR creator:\"plays\""))
    }

    func testCuratedCollectionsUseBroadCreatorQueries() {
        XCTAssertTrue(IACollectionStore.curated.map(\.id).contains("great-books"))
        XCTAssertTrue(IACollectionStore.curated.map(\.id).contains("great-books-spa"))
        XCTAssertTrue(IACollectionStore.curated.map(\.id).contains("great-books-deu"))
        XCTAssertTrue(IACollectionStore.curated.map(\.id).contains("great-books-ita"))
        XCTAssertTrue(IACollectionStore.curated.map(\.id).contains("great-books-grc"))
        XCTAssertTrue(IACollectionStore.curated.map(\.id).contains("greater-books"))
        XCTAssertEqual(IACollectionStore.curated.count, 6)

        XCTAssertTrue(CuratedQueries.greatBooks.contains(LibriVoxCatalogScope.query))
        XCTAssertTrue(CuratedQueries.greatBooks.contains("creator:\"Homer\""))
        XCTAssertTrue(CuratedQueries.greatBooks.contains("AND NOT creator:\"William John Locke\""))
        XCTAssertTrue(CuratedQueries.greaterBooks.contains("creator:\"Jane Austen\""))
    }

    func testStrictLibriVoxScopeExcludesGeneratedTTSCollections() {
        XCTAssertEqual(LibriVoxCatalogScope.collectionClause, "collection:librivoxaudio")
        XCTAssertEqual(LibriVoxCatalogScope.query, "collection:librivoxaudio AND mediatype:audio")
        XCTAssertFalse(LibriVoxCatalogScope.query.contains("audio_bookspoetry"))

        let generated = InternetArchiveSearchResult(
            identifier: "synapseml_gutenberg_the_eleven_comedies_volume_1_by_aristoph",
            title: "The Eleven Comedies",
            creators: ["Project Gutenberg", "Microsoft"],
            description: "Project Gutenberg TTS generated audio.",
            collections: ["audio_bookspoetry"],
            downloads: 10,
            date: nil
        )
        XCTAssertFalse(generated.isStrictLibriVoxCatalogCandidate)

        let librivox = InternetArchiveSearchResult(
            identifier: "clouds_librivox",
            title: "The Clouds",
            creators: ["Aristophanes"],
            description: nil,
            collections: ["librivoxaudio"],
            downloads: 100,
            date: nil
        )
        XCTAssertTrue(librivox.isStrictLibriVoxCatalogCandidate)
    }

    func testCoverImageFilesRejectSpectrogramDerivatives() {
        let metadata = InternetArchiveMetadata(
            metadata: InternetArchiveItemMetadata(
                identifier: "example_librivox",
                title: "Example",
                creators: ["Author"],
                description: nil,
                mediatype: "audio",
                collections: ["librivoxaudio"],
                subjects: [],
                language: "eng",
                callNumber: nil
            ),
            files: [
                InternetArchiveFile(
                    name: "example_spectrogram.png",
                    source: "derivative",
                    format: "PNG",
                    title: "Spectrogram",
                    length: nil,
                    track: nil,
                    size: "20000"
                ),
                InternetArchiveFile(
                    name: "cover.jpg",
                    source: "original",
                    format: "JPEG",
                    title: "Cover",
                    length: nil,
                    track: nil,
                    size: "30000"
                )
            ],
            server: nil,
            dir: nil
        )

        XCTAssertEqual(metadata.coverImageFiles.map(\.name), ["cover.jpg"])
    }

    func testAdvancedSearchURLUsesCatalogSortParameters() throws {
        let expectations: [(CatalogSort, [String])] = [
            (.popularity, ["downloads desc"]),
            (.title, ["titleSorter asc", "title asc"]),
            (.author, ["creatorSorter asc", "creator asc"]),
            (.recordedDate, ["date asc"])
        ]

        for (sort, expectedSorts) in expectations {
            let url = try XCTUnwrap(
                InternetArchiveClient.advancedSearchURL(
                    query: LibriVoxCatalogScope.query,
                    rows: 10,
                    page: 1,
                    sort: sort
                )
            )
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let sorts = (components.queryItems ?? [])
                .filter { $0.name == "sort[]" }
                .compactMap(\.value)
            XCTAssertEqual(sorts, expectedSorts, "Unexpected IA sort fields for \(sort)")
        }
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
