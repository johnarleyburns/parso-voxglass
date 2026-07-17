import Foundation
import XCTest
@testable import VoxglassCore

@MainActor
final class CollectionCoverStoreTests: XCTestCase {
    func testLiveCollectionResultArtworkWinsOverStaticRemoteArtwork() async throws {
        let defaultsName = "collection-cover-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)

        let liveResult = InternetArchiveSearchResult(
            identifier: "visible_collection_result",
            title: "Visible Collection Result",
            creators: ["Author"],
            description: nil,
            collections: ["librivoxaudio"],
            downloads: 100,
            date: "2007-01-01",
            languages: ["english"],
            subjects: ["Drama"]
        )
        let client = FakeCoverClient(results: [liveResult], numFound: 1)
        let store = CollectionCoverStore(
            client: client,
            artwork: AlwaysValidArtwork(),
            defaults: defaults
        )
        let collection = IACollection(
            id: "test-collection",
            title: "Test Collection",
            subtitle: "Test",
            archiveQuery: LibriVoxBrowseCategory.dramaPlays.archiveQuery,
            systemImage: "book",
            assetName: "collection-test",
            remoteImageURL: InternetArchiveMetadata.coverURL(for: "stale_static_result")
        )

        await store.resolveCovers(for: [collection], languages: ["eng"])

        XCTAssertEqual(store.coverURL(for: collection), liveResult.coverURL)
        let lastSort = await client.lastSort
        let lastQuery = await client.lastQuery ?? ""
        XCTAssertEqual(lastSort, .popularity)
        XCTAssertTrue(lastQuery.contains(LibriVoxCatalogScope.query))
    }

    func testResolvedArtworkIdentifierCacheSurvivesStoreRecreation() async throws {
        let defaultsName = "collection-cover-cache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)

        let liveResult = InternetArchiveSearchResult(
            identifier: "cached_collection_result",
            title: "Cached Collection Result",
            creators: ["Author"],
            description: nil,
            collections: ["librivoxaudio"],
            downloads: 100,
            date: "2007-01-01"
        )
        let collection = IACollection(
            id: "cached-collection",
            title: "Cached Collection",
            subtitle: "Test",
            archiveQuery: LibriVoxBrowseCategory.ancientWorld.archiveQuery,
            systemImage: "book",
            assetName: "collection-test"
        )
        let client = FakeCoverClient(results: [liveResult], numFound: 1)

        let firstStore = CollectionCoverStore(
            client: client,
            artwork: AlwaysValidArtwork(),
            defaults: defaults
        )
        await firstStore.resolveCovers(for: [collection], languages: ["eng"])

        let secondStore = CollectionCoverStore(
            client: FakeCoverClient(results: [], numFound: 0),
            artwork: AlwaysValidArtwork(),
            defaults: defaults
        )

        XCTAssertEqual(secondStore.coverURL(for: collection), liveResult.coverURL)
    }
}

private struct AlwaysValidArtwork: CoverArtworkValidating {
    func imageValidates(at url: URL) async -> Bool {
        true
    }
}

private final class FakeCoverClient: InternetArchiveCatalogClient {
    private let state: State

    var lastQuery: String? {
        get async { await state.lastQuery }
    }

    var lastSort: CatalogSort? {
        get async { await state.lastSort }
    }

    init(results: [InternetArchiveSearchResult], numFound: Int) {
        self.state = State(results: results, numFound: numFound)
    }

    func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
        []
    }

    func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
        []
    }

    func searchAdvancedPage(
        query: String,
        rows: Int,
        page: Int,
        sort: CatalogSort
    ) async throws -> InternetArchivePage {
        await state.page(query: query, page: page, sort: sort)
    }

    func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage {
        try await searchAdvancedPage(query: query, rows: rows, page: page, sort: .popularity)
    }

    func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
        throw InternetArchiveError.itemNotFound(identifier)
    }

    private actor State {
        private let results: [InternetArchiveSearchResult]
        private let numFound: Int
        private(set) var lastQuery: String?
        private(set) var lastSort: CatalogSort?

        init(results: [InternetArchiveSearchResult], numFound: Int) {
            self.results = results
            self.numFound = numFound
        }

        func page(query: String, page: Int, sort: CatalogSort) -> InternetArchivePage {
            lastQuery = query
            lastSort = sort
            return InternetArchivePage(results: results, numFound: numFound, page: page)
        }
    }
}
