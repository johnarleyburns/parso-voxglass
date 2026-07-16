import XCTest
import UIKit
@testable import VoxglassCore

final class PostFieldTestImprovementsTests: XCTestCase {

    // MARK: - §4 Alphabetical sort

    func testFeaturedCollectionsAreSortedPopularCuratedThenAlphabetical() {
        let titles = IACollectionStore.collections(for: []).map(\.title)

        // Popular is always first
        XCTAssertEqual(titles.first, "Popular LibriVox")

        // Curated collections come right after popular (in fixed order)
        let curatedStart = titles.dropFirst().prefix(3)
        XCTAssertEqual(Array(curatedStart), ["Great Books", "Greater Books", "Ancient Greece"])

        // Remaining browse collections are sorted alphabetically
        let browse = Array(titles.dropFirst(4))
        let expectedBrowse = browse.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(browse, expectedBrowse)
    }

    func testFeaturedCollectionSortIgnoresSelection() {
        let unselected = IACollectionStore.collections(for: [])
        let selected = IACollectionStore.collections(for: ["lv-poetry", "great-books"])
        XCTAssertEqual(unselected.map(\.id), selected.map(\.id))
    }

    func testFeaturedCollectionsIncludePopularBrowseAndCurated() {
        let ids = Set(IACollectionStore.collections(for: []).map(\.id))
        XCTAssertTrue(ids.contains("popular-librivox"))
        XCTAssertTrue(ids.contains("great-books"))
        XCTAssertTrue(ids.contains("lv-science-fiction"))
        XCTAssertEqual(ids.count, 1 + 21 + 3)
    }

    // MARK: - §1 Language clause

    func testLanguageClauseEmptyForEmptySelection() {
        XCTAssertEqual(LibriVoxLanguage.clause(for: []), "")
    }

    func testLanguageClauseWrapsSelectedTokensWithOr() {
        let clause = LibriVoxLanguage.clause(for: ["eng"])
        XCTAssertEqual(clause, " AND (language:eng OR language:English)")
    }

    func testLanguageClauseCombinesMultipleLanguages() {
        let clause = LibriVoxLanguage.clause(for: ["eng", "deu"])
        XCTAssertTrue(clause.hasPrefix(" AND ("))
        XCTAssertTrue(clause.contains("language:eng"))
        XCTAssertTrue(clause.contains("language:deu"))
        XCTAssertTrue(clause.contains("language:ger"))
    }

    func testLanguageClauseIgnoresUnknownCodes() {
        XCTAssertEqual(LibriVoxLanguage.clause(for: ["nonsense"]), "")
    }

    func testCuratedQueriesNoLongerHardcodeEnglish() {
        XCTAssertFalse(CuratedQueries.greatBooks.contains("language:eng"))
        XCTAssertFalse(CuratedQueries.greaterBooks.contains("language:eng"))
    }

    func testPreferencesEncodeDecodeLanguagesRoundTrip() {
        let encoded = AppPreferencesStore.encodeLanguages(["deu", "eng"])
        XCTAssertEqual(encoded, "deu,eng")
        XCTAssertEqual(AppPreferencesStore.decodeLanguages(encoded), ["deu", "eng"])
    }

    func testSearchResultsDecodeLanguageField() throws {
        let json = """
        { "response": { "numFound": 1, "docs": [
            { "identifier": "a", "title": "A", "language": ["eng", "German"] }
        ] } }
        """
        let response = try JSONDecoder().decode(InternetArchiveSearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.results.first?.languages, ["eng", "German"])
    }

    // MARK: - §2 Pagination

    func testSearchResponseDecodesNumFound() throws {
        let json = """
        { "response": { "numFound": 4321, "docs": [] } }
        """
        let response = try JSONDecoder().decode(InternetArchiveSearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.numFound, 4321)
    }

    @MainActor
    func testLoadMoreAppendsDistinctResultsAndClearsHasMore() async {
        let client = PagingMockClient(pageSize: 2, total: 5)
        let store = CatalogStore(client: client)
        store.selectedLanguages = []

        await store.searchAdvanced("collection:librivoxaudio")
        XCTAssertEqual(store.results.count, 2)
        XCTAssertTrue(store.hasMore)

        await store.loadMore()
        XCTAssertEqual(store.results.count, 4)
        XCTAssertTrue(store.hasMore)

        await store.loadMore()
        XCTAssertEqual(store.results.count, 5)
        XCTAssertFalse(store.hasMore)

        let identifiers = store.results.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    @MainActor
    func testChangingLanguagesReRunsActiveQuery() async {
        let client = PagingMockClient(pageSize: 25, total: 3)
        let store = CatalogStore(client: client)
        store.selectedLanguages = []

        await store.searchAdvanced("collection:librivoxaudio")
        let firstCount = client.queries.count
        XCTAssertGreaterThan(firstCount, 0)

        store.selectedLanguages = ["eng"]
        // allow the didSet-triggered Task to run
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(client.queries.last?.contains("language:eng") == true)
    }

    // MARK: - §3 Collection cover resolution

    @MainActor
    func testCollectionCoverStoreResolvesNonNilCoverForAllCollections() async {
        let client = AlwaysResultsMockClient()
        let artwork = Self.alwaysValidArtworkService()
        let defaults = Self.ephemeralDefaults()
        let store = CollectionCoverStore(client: client, artwork: artwork, defaults: defaults)

        let collections = IACollectionStore.collections(for: [])
        await store.resolveCovers(for: collections, languages: ["eng"])

        for collection in collections {
            XCTAssertNotNil(store.coverURL(for: collection), "No cover resolved for \(collection.id)")
        }
    }

    /// A real `ArtworkService` whose fetcher always returns a valid, large-enough
    /// PNG so `validatedImage` accepts it — lets us exercise cover resolution
    /// without touching the network.
    private static func alwaysValidArtworkService() -> ArtworkService {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let data = renderer.pngData { context in
            UIColor.brown.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-\(UUID().uuidString)", isDirectory: true)
        return ArtworkService(
            cacheDirectory: tempDir,
            fetcher: { _ in (data, nil) },
            registerBytes: { _, _ in },
            touchKey: { _ in }
        )
    }

    private static func ephemeralDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

// MARK: - Mocks

private final class PagingMockClient: InternetArchiveCatalogClient {
    let pageSize: Int
    let total: Int
    private(set) var queries: [String] = []

    init(pageSize: Int, total: Int) {
        self.pageSize = pageSize
        self.total = total
    }

    func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: query, rows: rows, page: 1).results
    }

    func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: identifier, rows: rows, page: 1).results
    }

    func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage {
        queries.append(query)
        let start = (page - 1) * pageSize
        let end = min(start + pageSize, total)
        let results = (start..<max(start, end)).map { index in
            InternetArchiveSearchResult(
                identifier: "item-\(index)",
                title: "Item \(index)",
                creators: ["Author"],
                description: nil,
                collections: ["librivoxaudio"],
                downloads: total - index,
                date: nil
            )
        }
        return InternetArchivePage(results: results, numFound: total, page: page)
    }

    func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
        throw InternetArchiveError.itemNotFound(identifier)
    }
}

private final class AlwaysResultsMockClient: InternetArchiveCatalogClient {
    func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: query, rows: rows, page: 1).results
    }

    func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
        try await searchAdvancedPage(query: identifier, rows: rows, page: 1).results
    }

    func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage {
        let results = [
            InternetArchiveSearchResult(
                identifier: "cover-\(abs(query.hashValue))",
                title: "Cover",
                creators: ["Author"],
                description: nil,
                collections: ["librivoxaudio"],
                downloads: 100,
                date: nil
            )
        ]
        return InternetArchivePage(results: results, numFound: 1, page: page)
    }

    func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
        throw InternetArchiveError.itemNotFound(identifier)
    }
}
