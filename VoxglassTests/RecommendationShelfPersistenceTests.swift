import XCTest
@testable import VoxglassCore

@MainActor
final class RecommendationShelfPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "reco-shelf-persistence-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testColdLaunchHydratesPersistedPersonalizedShelf() async throws {
        let personalized = [
            candidate(identifier: "persisted_frogs", title: "The Frogs", creator: "Aristophanes"),
            candidate(identifier: "persisted_birds", title: "The Birds", creator: "Aristophanes")
        ]
        HomeRecommendationStore.saveSnapshot(
            RecommendationShelfSnapshot(results: personalized, source: .personalized, savedAt: Date()),
            to: defaults
        )

        let client = ShelfFakeArchiveClient(responses: [])
        let store = HomeRecommendationStore(client: client, defaults: defaults)
        let queryCount = await client.advancedQueryCount

        XCTAssertEqual(
            store.recommendations.map(\.identifier),
            ["persisted_frogs", "persisted_birds"],
            "a fresh store must hydrate the persisted personalized shelf, not bundled popular seeds"
        )
        XCTAssertEqual(queryCount, 0, "hydration must not touch the network")
    }

    func testColdLaunchWithoutSnapshotFallsBackToBundledSeeds() {
        let store = HomeRecommendationStore(client: ShelfFakeArchiveClient(responses: []), defaults: defaults)

        XCTAssertEqual(
            store.recommendations.map(\.identifier),
            HomeRecommendationStore.bundledPopularSeeds.map(\.identifier)
        )
    }

    func testCorruptSnapshotFallsBackToBundledSeeds() {
        defaults.set(Data("not json".utf8), forKey: HomeRecommendationStore.shelfSnapshotKey)

        let store = HomeRecommendationStore(client: ShelfFakeArchiveClient(responses: []), defaults: defaults)

        XCTAssertEqual(
            store.recommendations.map(\.identifier),
            HomeRecommendationStore.bundledPopularSeeds.map(\.identifier)
        )
    }

    func testPopularColdStartDoesNotReplaceVisiblePersonalizedShelf() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "shelf-guard-cold-start")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.upsertTerm(axis: "author", term: "Aristophanes", increment: 5)
        await libraryStore.refresh()

        let personalized = candidate(
            identifier: "aristophanes_frogs",
            title: "The Frogs",
            creator: "Aristophanes",
            downloads: 400,
            subjects: ["Drama"]
        )
        let store = HomeRecommendationStore(
            client: ShelfFakeArchiveClient(responses: [[personalized]]),
            defaults: defaults
        )
        store.configure(profileStore: profileStore, libraryStore: libraryStore)
        store.markEngineReady()

        await store.load(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        XCTAssertEqual(store.recommendations.map(\.identifier), ["aristophanes_frogs"])

        try await database.execute("DELETE FROM taste_profile_terms")

        await store.load(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        XCTAssertEqual(
            store.recommendations.map(\.identifier),
            ["aristophanes_frogs"],
            "a visible personalized shelf must never be replaced by a popular cold-start shelf"
        )
    }

    func testPersonalizedShelfIsPersistedWhenLoaded() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "shelf-persist-on-load")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await profileStore.upsertTerm(axis: "author", term: "Aristophanes", increment: 5)
        await libraryStore.refresh()

        let personalized = candidate(
            identifier: "aristophanes_frogs",
            title: "The Frogs",
            creator: "Aristophanes",
            downloads: 400,
            subjects: ["Drama"]
        )
        let store = HomeRecommendationStore(
            client: ShelfFakeArchiveClient(responses: [[personalized]]),
            defaults: defaults
        )
        store.configure(profileStore: profileStore, libraryStore: libraryStore)
        store.markEngineReady()

        await store.load(selectedCollectionIDs: [], selectedLanguages: ["eng"])
        XCTAssertEqual(store.recommendations.map(\.identifier), ["aristophanes_frogs"])

        let snapshot = try XCTUnwrap(
            HomeRecommendationStore.loadSnapshot(from: defaults),
            "loading a personalized shelf must persist a snapshot"
        )
        XCTAssertEqual(snapshot.source, .personalized)
        XCTAssertEqual(snapshot.results.map(\.identifier), ["aristophanes_frogs"])
    }

    func testPopularShelvesAreNotPersisted() async throws {
        let database = AppDatabase.makeTemporaryDatabase(named: "shelf-no-persist-popular")
        let repository = LibraryRepository(database: database)
        let libraryStore = LibraryStore(repository: repository)
        let profileStore = TasteProfileStore(database: database)
        await libraryStore.refresh()

        let store = HomeRecommendationStore(
            client: ShelfFakeArchiveClient(responses: []),
            defaults: defaults
        )
        store.configure(profileStore: profileStore, libraryStore: libraryStore)
        store.markEngineReady()

        await store.load(selectedCollectionIDs: [], selectedLanguages: ["eng"])

        XCTAssertNil(HomeRecommendationStore.loadSnapshot(from: defaults))
    }

    func testSnapshotRoundTripsThroughCodable() throws {
        let snapshot = RecommendationShelfSnapshot(
            results: [candidate(identifier: "round_trip", title: "The Clouds", creator: "Aristophanes")],
            source: .personalized,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        HomeRecommendationStore.saveSnapshot(snapshot, to: defaults)
        let decoded = try XCTUnwrap(HomeRecommendationStore.loadSnapshot(from: defaults))

        XCTAssertEqual(decoded, snapshot)
    }

    // MARK: - Helpers

    private func candidate(
        identifier: String,
        title: String,
        creator: String,
        downloads: Int? = nil,
        subjects: [String] = [],
        collections: [String] = ["librivoxaudio"]
    ) -> InternetArchiveSearchResult {
        InternetArchiveSearchResult(
            identifier: identifier,
            title: title,
            creators: [creator],
            description: nil,
            collections: collections,
            downloads: downloads,
            date: nil,
            languages: ["english"],
            subjects: subjects
        )
    }

    private final class ShelfFakeArchiveClient: InternetArchiveCatalogClient {
        private let state: State

        var advancedQueryCount: Int {
            get async { await state.advancedQueryCount }
        }

        init(responses: [[InternetArchiveSearchResult]]) {
            self.state = State(responses: responses)
        }

        func searchLibriVox(query: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
            []
        }

        func searchCollection(identifier: String, rows: Int) async throws -> [InternetArchiveSearchResult] {
            []
        }

        func searchAdvancedPage(query: String, rows: Int, page: Int) async throws -> InternetArchivePage {
            let response = await state.nextResponse(for: query)
            return InternetArchivePage(results: response, numFound: response.count, page: page)
        }

        func metadata(for identifier: String) async throws -> InternetArchiveMetadata {
            throw InternetArchiveError.itemNotFound(identifier)
        }

        private actor State {
            private let responses: [[InternetArchiveSearchResult]]
            private var queries: [String] = []

            var advancedQueryCount: Int { queries.count }

            init(responses: [[InternetArchiveSearchResult]]) {
                self.responses = responses
            }

            func nextResponse(for query: String) -> [InternetArchiveSearchResult] {
                queries.append(query)
                let index = queries.count - 1
                return index < responses.count ? responses[index] : []
            }
        }
    }
}
