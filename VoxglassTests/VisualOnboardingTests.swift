import UIKit
import XCTest
@testable import Voxglass

final class VisualOnboardingTests: XCTestCase {
    func testOnboardingChipsAreUniqueAndHaveArchiveQueries() {
        let collections = IACollectionStore.allSelectableCollections
        let ids = Set(collections.map(\.id))
        let titles = Set(collections.map(\.title))

        XCTAssertEqual(collections.count, 24, "Expected 21 browse categories + 3 curated collections")
        XCTAssertEqual(ids.count, collections.count)
        XCTAssertEqual(titles.count, collections.count)
        XCTAssertTrue(collections.allSatisfy { $0.archiveQuery.contains("collection:librivoxaudio") })
        XCTAssertTrue(collections.allSatisfy { !$0.archiveQuery.contains("http://") && !$0.archiveQuery.contains("https://") })
    }

    func testColdStartRecommendationsReturnBundledPopularTitles() {
        let recommendations = HomeRecommendationStore.coldStartRecommendations(for: [])

        XCTAssertFalse(recommendations.isEmpty)
        XCTAssertEqual(recommendations, HomeRecommendationStore.bundledPopularSeeds)
        XCTAssertTrue(recommendations.allSatisfy { $0.sourceKind == .librivox })
        XCTAssertTrue(recommendations.allSatisfy { $0.coverURL.absoluteString.contains("/services/img/") })
    }

    func testSelectedChipsBuildExpectedLibriVoxArchiveQueries() {
        let queries = LibriVoxRecommendationQueryBuilder.queries(for: ["lv-mystery-crime", "lv-science-fiction"])

        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries.contains { $0.contains("Crime & Mystery Fiction") })
        XCTAssertTrue(queries.contains { $0.contains("Science Fiction") })
        XCTAssertEqual(
            LibriVoxRecommendationQueryBuilder.queries(for: []),
            [LibriVoxBrowseCategory.popular.archiveQuery]
        )
    }

    func testInternetArchiveCoverURLUsesServicesImageEndpoint() {
        XCTAssertEqual(
            InternetArchiveMetadata.coverURL(for: "pride_and_prejudice_librivox").absoluteString,
            "https://archive.org/services/img/pride_and_prejudice_librivox?scale=2"
        )
    }

    @MainActor
    func testArtworkCacheReturnsCachedImageAndRejectsBadResponses() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-artwork-tests-\(UUID().uuidString)", isDirectory: true)
        let imageURL = URL(string: "https://archive.org/services/img/test_item")!
        let response = HTTPURLResponse(url: imageURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let validPNG = try pngData(width: 48, height: 72)
        let fetchBox = FetchBox(data: validPNG, response: response)
        let service = ArtworkService(cacheDirectory: tempDirectory, timeToLive: 60, fetcher: fetchBox.fetch)

        let first = try await service.loadImage(for: imageURL)
        let second = try await service.loadImage(for: imageURL)

        XCTAssertEqual(fetchBox.count, 1)
        XCTAssertEqual(first.size, second.size)
        XCTAssertNotNil(service.cachedImage(for: imageURL))

        XCTAssertThrowsError(try ArtworkService.validatedImage(from: Data("notfound".utf8), response: response)) { error in
            XCTAssertEqual(error as? ArtworkServiceError, .notFoundImage)
        }
        let tinyPNG = try pngData(width: 1, height: 1)
        XCTAssertThrowsError(try ArtworkService.validatedImage(from: tinyPNG, response: response)) { error in
            XCTAssertEqual(error as? ArtworkServiceError, .tinyImage)
        }
    }

    func testRecentlyViewedBooksAreHiddenUntilAViewEventIsRecorded() {
        let sourceID = UUID()
        let bookID = UUID()
        let book = BookWithChapters(
            book: Book(id: bookID, title: "Viewed Book", authors: ["Author"], sourceID: sourceID),
            chapters: []
        )

        XCTAssertTrue(RecentlyViewedBooksStore.books(from: [book], rawValue: "").isEmpty)

        let rawValue = RecentlyViewedBooksStore.recording(bookID: bookID, in: "")
        let viewed = RecentlyViewedBooksStore.books(from: [book], rawValue: rawValue)

        XCTAssertEqual(viewed.map(\.book.id), [bookID])
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }
}

private final class FetchBox: @unchecked Sendable {
    var count = 0
    let data: Data
    let response: URLResponse

    init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }

    func fetch(_ url: URL) async throws -> (Data, URLResponse?) {
        count += 1
        return (data, response)
    }
}
