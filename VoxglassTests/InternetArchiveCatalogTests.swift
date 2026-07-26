import Testing
import Foundation
@testable import VoxglassCore

@Suite struct InternetArchiveCatalogTests {
    private let decoder = JSONDecoder()

    @Test func advancedSearchFixtureDecodesLibriVoxResults() throws {
        let data = try fixtureData("advanced_search_librivox")
        let response = try decoder.decode(InternetArchiveSearchResponse.self, from: data)

        #expect(response.results.count == 2)
        #expect(response.results[0].identifier == "pride_and_prejudice_librivox")
        #expect(response.results[0].title == "Pride and Prejudice")
        #expect(response.results[0].authorLine == "Jane Austen")
        #expect(response.results[0].sourceKind == .librivox)
        #expect(response.results[1].creators == ["Various"])
        #expect(response.results[1].downloads == 678)
    }

    @Test func metadataFixtureDeduplicatesAudioDerivativesByQuality() throws {
        let metadata = try metadataFixture()
        let selected = metadata.selectedAudioFiles

        #expect(selected.map(\.name) == [
            "01 Chapter One.mp3",
            "02 Chapter Two_vbr.mp3",
            "10 Chapter Ten_64kb.mp3"
        ])
    }

    @Test func metadataFixtureBuildsNaturalChapterOrderAndDurations() throws {
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

        #expect(chapters.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 10"])
        #expect(chapters.map(\.duration) == [100, 200, 600])
        #expect(chapters[0].remoteURL?.absoluteString == "https://archive.org/download/pride_and_prejudice_librivox/01%20Chapter%20One.mp3")
    }

    @Test func archiveURLParserRecognizesItemMetadataDownloadAndSearchURLs() {
        #expect(InternetArchiveURLParser.parse("https://archive.org/details/pride_and_prejudice_librivox") == .identifier("pride_and_prejudice_librivox"))
        #expect(InternetArchiveURLParser.parse("archive.org/metadata/pride_and_prejudice_librivox") == .identifier("pride_and_prejudice_librivox"))
        #expect(InternetArchiveURLParser.parse("https://archive.org/download/pride_and_prejudice_librivox/01%20Chapter%20One.mp3") == .identifier("pride_and_prejudice_librivox"))
        #expect(InternetArchiveURLParser.parse("https://archive.org/advancedsearch.php?q=collection%3A%28librivoxaudio%29") == .advancedSearch(query: "collection:(librivoxaudio)"))
    }

    @Test func libriVoxBrowseCategoriesUseSemanticArchiveQueries() {
        let categories = LibriVoxBrowseGroup.categories
        let ids = Set(categories.map(\.id))

        #expect(categories.count == 20)
        #expect(ids.count == categories.count)
        #expect(LibriVoxBrowseGroup.all.map(\.title) == ["Fiction", "Forms", "Ideas & Nonfiction"])
        #expect(categories.allSatisfy { $0.archiveQuery.contains(LibriVoxCatalogScope.collectionClause) })
        #expect(categories.allSatisfy { !$0.archiveQuery.contains("audio_bookspoetry") })
        #expect(categories.allSatisfy { $0.archiveQuery.contains("mediatype:audio") })
        #expect(categories.allSatisfy { !$0.archiveQuery.contains("http://") && !$0.archiveQuery.contains("https://") })
        #expect(LibriVoxBrowseCategory.scienceFiction.archiveQuery.contains("subject:\"Science Fiction\""))
        #expect(LibriVoxBrowseCategory.philosophyMind.archiveQuery.contains("AND NOT"))
    }

    @Test func internetArchiveImportRoundTripsAndDeduplicatesInDatabase() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "internet-archive-import")
        let repository = LibraryRepository(database: database)
        let metadata = try metadataFixture()

        let first = try await repository.importInternetArchiveItem(metadata, sourceKind: .librivox)
        let second = try await repository.importInternetArchiveItem(metadata, sourceKind: .librivox)
        let library = try await repository.fetchLibrary()

        #expect(first.book.id == second.book.id)
        #expect(library.count == 1)
        #expect(library[0].book.title == "Pride and Prejudice")
        #expect(library[0].book.authors == ["Jane Austen"])
        #expect(library[0].chapters.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 10"])
        #expect(library[0].book.summary == "LibriVox recording & public-domain audiobook.")
    }

    @Test func libriVoxQueryBuilderScopesToLibriVoxWithBoostsAndPhraseClause() {
        let query = InternetArchiveClient.libriVoxQuery(for: "sherlock holmes")

        #expect(query.contains(LibriVoxCatalogScope.query))
        // Whole-phrase boost clause across title/subject/description.
        #expect(query.contains("title:\"sherlock holmes\"^8"))
        #expect(query.contains("subject:\"sherlock holmes\"^6"))
        #expect(query.contains("description:\"sherlock holmes\"^4"))
        // Per-token clause now includes subject + description fields.
        #expect(query.contains("title:\"sherlock\"^4"))
        #expect(query.contains("creator:\"sherlock\"^3"))
        #expect(query.contains("subject:\"holmes\"^2"))
        #expect(query.contains("description:\"holmes\"^1"))
        #expect(query.contains("collection:librivoxaudio"))
        #expect(!(query.contains("audio_bookspoetry")))
        #expect(query.contains(") OR ("))
    }

    @Test func libriVoxQueryBuilderHandlesEmptyInput() {
        let query = InternetArchiveClient.libriVoxQuery(for: "   ")
        #expect(query == LibriVoxCatalogScope.query)
    }

    @Test func libriVoxQueryBuilderAllowsSubjectAnchoredThematicSearch() {
        // Regression for §8: "greek plays" must be satisfiable via subject/
        // description (no mandatory title/creator-only anchor).
        let query = InternetArchiveClient.libriVoxQuery(for: "greek plays")

        #expect(query.contains("subject:\"greek\"^2"))
        #expect(query.contains("subject:\"plays\"^2"))
        #expect(query.contains("title:\"greek plays\"^8"))
        // No bare (unboosted) title/creator-only mandatory clause remains.
        #expect(!(query.contains("title:\"greek\" OR creator:\"greek\"")))
        #expect(!(query.contains("title:\"plays\" OR creator:\"plays\"")))
    }

    @Test func curatedCollectionsUseBroadCreatorQueries() {
        #expect(IACollectionStore.curated.map(\.id).contains("great-books"))
        #expect(IACollectionStore.curated.map(\.id).contains("great-books-spa"))
        #expect(IACollectionStore.curated.map(\.id).contains("great-books-deu"))
        #expect(IACollectionStore.curated.map(\.id).contains("great-books-ita"))
        #expect(IACollectionStore.curated.map(\.id).contains("great-books-grc"))
        #expect(IACollectionStore.curated.map(\.id).contains("greater-books"))
        #expect(IACollectionStore.curated.count == 6)

        #expect(CuratedQueries.greatBooks.contains(LibriVoxCatalogScope.query))
        #expect(CuratedQueries.greatBooks.contains("creator:\"Homer\""))
        #expect(CuratedQueries.greatBooks.contains("AND NOT creator:\"William John Locke\""))
        #expect(CuratedQueries.greaterBooks.contains("creator:\"Jane Austen\""))
    }

    @Test func strictLibriVoxScopeExcludesGeneratedTTSCollections() {
        #expect(LibriVoxCatalogScope.collectionClause == "collection:librivoxaudio")
        #expect(LibriVoxCatalogScope.query == "collection:librivoxaudio AND mediatype:audio")
        #expect(!(LibriVoxCatalogScope.query.contains("audio_bookspoetry")))

        let generated = InternetArchiveSearchResult(
            identifier: "synapseml_gutenberg_the_eleven_comedies_volume_1_by_aristoph",
            title: "The Eleven Comedies",
            creators: ["Project Gutenberg", "Microsoft"],
            description: "Project Gutenberg TTS generated audio.",
            collections: ["audio_bookspoetry"],
            downloads: 10,
            date: nil
        )
        #expect(!(generated.isStrictLibriVoxCatalogCandidate))

        let librivox = InternetArchiveSearchResult(
            identifier: "clouds_librivox",
            title: "The Clouds",
            creators: ["Aristophanes"],
            description: nil,
            collections: ["librivoxaudio"],
            downloads: 100,
            date: nil
        )
        #expect(librivox.isStrictLibriVoxCatalogCandidate)
    }

    @Test func coverImageFilesRejectSpectrogramDerivatives() {
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

        #expect(metadata.coverImageFiles.map(\.name) == ["cover.jpg"])
    }

    @Test func advancedSearchURLUsesCatalogSortParameters() throws {
        let expectations: [(CatalogSort, [String])] = [
            (.popularity, ["downloads desc"]),
            (.title, ["titleSorter asc", "title asc"]),
            (.author, ["creatorSorter asc", "creator asc"]),
            (.recordedDate, ["date asc"])
        ]

        for (sort, expectedSorts) in expectations {
            let url = try try #require(InternetArchiveClient.advancedSearchURL(
                    query: LibriVoxCatalogScope.query,
                    rows: 10,
                    page: 1,
                    sort: sort
                ))
            let components = try try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let sorts = (components.queryItems ?? [])
                .filter { $0.name == "sort[]" }
                .compactMap(\.value)
            #expect(sorts == expectedSorts)  // Unexpected IA sort fields for \(sort)
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
