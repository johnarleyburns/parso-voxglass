import UIKit
import XCTest
@testable import Voxglass

final class CoverResolutionTests: XCTestCase {

    // MARK: - §1 Threshold: 1KB floor in isIAUnwantedPlaceholder

    func testAcceptsSolidCoverBetween1KBAnd8KB() throws {
        let data = try solidJPEGData(width: 180, height: 180)
        XCTAssertLessThan(data.count, 8_000, "Solid 180x180 JPEG must be below old 8 KB threshold")
        XCTAssertGreaterThanOrEqual(data.count, 1_000, "Solid 180x180 JPEG must be above new 1 KB floor")

        let response = HTTPURLResponse(
            url: URL(string: "https://archive.org/services/img/test_item")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
        )!

        XCTAssertNoThrow(try ArtworkService.validatedImage(from: data, response: response))
    }

    func testRejectsTinySolidCoverBelow1KB() throws {
        let data = try solidJPEGData(width: 24, height: 24)
        XCTAssertLessThan(data.count, 1_000, "24x24 solid JPEG must be below 1 KB floor")

        let response = HTTPURLResponse(
            url: URL(string: "https://archive.org/services/img/test_item")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
        )!

        XCTAssertThrowsError(try ArtworkService.validatedImage(from: data, response: response)) { error in
            XCTAssertEqual(error as? ArtworkServiceError, .notFoundImage)
        }
    }

    func testStillRejects120x120PlaceholderSquare() throws {
        let data = try solidJPEGData(width: 120, height: 120)

        let response = HTTPURLResponse(
            url: URL(string: "https://archive.org/services/img/test_item")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
        )!

        XCTAssertThrowsError(try ArtworkService.validatedImage(from: data, response: response)) { error in
            XCTAssertEqual(error as? ArtworkServiceError, .notFoundImage)
        }
    }

    // MARK: - §2 extractIAIdentifier

    func testExtractsIdentifierFromServicesImgURL() {
        let url = URL(string: "https://archive.org/services/img/adventures_holmes?scale=2")!
        XCTAssertEqual(ArtworkService.extractIAIdentifier(from: url), "adventures_holmes")
    }

    func testExtractsIdentifierWithoutQueryString() {
        let url = URL(string: "https://archive.org/services/img/frankenstein_shelley")!
        XCTAssertEqual(ArtworkService.extractIAIdentifier(from: url), "frankenstein_shelley")
    }

    func testExtractIdentifierRejectsNonArchiveHost() {
        let url = URL(string: "https://example.com/services/img/adventures_holmes")!
        XCTAssertNil(ArtworkService.extractIAIdentifier(from: url))
    }

    func testExtractIdentifierRejectsNonServicesImgPath() {
        let url = URL(string: "https://archive.org/details/adventures_holmes")!
        XCTAssertNil(ArtworkService.extractIAIdentifier(from: url))
    }

    func testExtractIdentifierRejectsNotFoundAsset() {
        let url = URL(string: "https://archive.org/services/img/notfound.png?scale=2")!
        XCTAssertNil(ArtworkService.extractIAIdentifier(from: url))
    }

    func testExtractIdentifierRejectsEmptyLastComponent() {
        let url = URL(string: "https://archive.org/services/img/?scale=2")!
        XCTAssertNil(ArtworkService.extractIAIdentifier(from: url))
    }

    // MARK: - §3 coverImageFiles

    func testCoverImageFilesFiltersNonImages() throws {
        let metadata = makeMetadata(files: [
            makeFile(name: "cover.jpg", format: "JPEG", size: "5000"),
            makeFile(name: "chapter01.mp3", format: "MP3", size: "10000"),
            makeFile(name: "metadata.xml", format: "Metadata", size: "500"),
            makeFile(name: "cover_back.png", format: "PNG", size: "7000")
        ])
        let coverFiles = metadata.coverImageFiles
        XCTAssertEqual(coverFiles.count, 2)
        let names = Set(coverFiles.map(\.name))
        XCTAssertEqual(names, Set(["cover.jpg", "cover_back.png"]))
        // Larger file should sort first among non-thumb files
        XCTAssertEqual(coverFiles.first?.name, "cover_back.png")
    }

    func testCoverImageFilesFiltersSpectrograms() throws {
        let metadata = makeMetadata(files: [
            makeFile(name: "cover.jpg", format: "JPEG", size: "5000"),
            makeFile(name: "chapter01_spectrogram.png", format: "Spectrogram PNG", size: "50000"),
            makeFile(name: "chapter02.png", format: "PNG", size: "9000")
        ])
        let coverFiles = metadata.coverImageFiles
        XCTAssertEqual(coverFiles.count, 2)
        // Larger file first among non-thumb files
        XCTAssertEqual(coverFiles.first?.name, "chapter02.png")
    }

    func testCoverImageFilesSortsThumbFilesFirst() throws {
        let metadata = makeMetadata(files: [
            makeFile(name: "cover_full.jpg", format: "JPEG", size: "50000"),
            makeFile(name: "cover_thumb.jpg", format: "JPEG Thumb", size: "5000"),
            makeFile(name: "__ia_thumb.jpg", format: "JPEG", size: "3000")
        ])
        let coverFiles = metadata.coverImageFiles
        XCTAssertEqual(coverFiles.count, 3)
        // Thumb files sort first; among thumbs, largest first
        XCTAssertTrue(coverFiles[0].name.contains("thumb"))
        XCTAssertTrue(coverFiles[1].name.contains("thumb"))
    }

    func testCoverImageFilesEmptyWhenNoImages() throws {
        let metadata = makeMetadata(files: [
            makeFile(name: "chapter01.mp3", format: "MP3", size: "10000"),
            makeFile(name: "metadata.xml", format: "Metadata", size: "500")
        ])
        let coverFiles = metadata.coverImageFiles
        XCTAssertEqual(coverFiles.count, 0)
    }

    // MARK: - §4 bestCoverURL (LibraryRepository helper)

    func testBestCoverURLPrefersMetadataThumbOverServicesImg() throws {
        let metadata = makeMetadata(files: [
            makeFile(name: "__ia_thumb.jpg", format: "JPEG", size: "5000"),
            makeFile(name: "chapter01.mp3", format: "MP3", size: "10000")
        ])
        let url = callBestCoverURL(identifier: "test_item", metadata: metadata)

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("download"), "Should use download URL")
        XCTAssertTrue(url!.absoluteString.contains("__ia_thumb.jpg"))
    }

    func testBestCoverURLFallsBackToServicesImgWhenNoCoverFiles() throws {
        let metadata = makeMetadata(files: [
            makeFile(name: "chapter01.mp3", format: "MP3", size: "10000")
        ])
        let url = callBestCoverURL(identifier: "test_item", metadata: metadata)

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("services/img"))
    }

    func testBestCoverURLFallsBackToServicesImgWhenFilesEmpty() throws {
        let metadata = makeMetadata(files: [])
        let url = callBestCoverURL(identifier: "test_item", metadata: metadata)

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("services/img"))
    }

    // MARK: - §5 ArtworkService lazy repair

    @MainActor
    func testImageLoadReturnsNilWhenBothPrimaryAndFallbackFail() async throws {
        let primaryURL = URL(string: "https://archive.org/services/img/broken_item?scale=2")!
        let brokenResponse = HTTPURLResponse(
            url: primaryURL, statusCode: 404, httpVersion: nil, headerFields: nil
        )!

        let fetcher: @Sendable (URL) async throws -> (Data, URLResponse?) = { url in
            return (Data(), brokenResponse)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-cover-resolution-\(UUID().uuidString)", isDirectory: true)
        let service = ArtworkService(
            cacheDirectory: tempDirectory,
            timeToLive: 60,
            fetcher: fetcher
        )

        let image = await service.image(for: primaryURL)
        XCTAssertNil(image, "Should return nil when both primary and fallback fail")
    }

    @MainActor
    func testImageLoadSucceedsWhenPrimaryIsValid() async throws {
        let primaryURL = URL(string: "https://archive.org/services/img/good_item?scale=2")!
        let data = try solidJPEGData(width: 180, height: 180)
        let validResponse = HTTPURLResponse(
            url: primaryURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
        )!

        let fetcher: @Sendable (URL) async throws -> (Data, URLResponse?) = { url in
            return (data, validResponse)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-cover-resolution-\(UUID().uuidString)", isDirectory: true)
        let service = ArtworkService(
            cacheDirectory: tempDirectory,
            timeToLive: 60,
            fetcher: fetcher
        )

        let image = await service.image(for: primaryURL)
        XCTAssertNotNil(image, "Should load valid image from primary URL")
    }

    // MARK: - §6 InternetArchiveCoverResolver caching

    @MainActor
    func testResolverReturnsConsistentResultForSameIdentifier() async throws {
        let resolver = InternetArchiveCoverResolver()
        await resolver.clearCache()

        let identifier = "nonexistent_item_resolver_cache_test"
        let url1 = await resolver.resolve(for: identifier)
        let url2 = await resolver.resolve(for: identifier)

        XCTAssertEqual(url1, url2, "Resolver should return consistent cached result")
    }

    // MARK: - Helpers

    private func callBestCoverURL(identifier: String, metadata: InternetArchiveMetadata) -> URL? {
        LibraryRepository.bestCoverURL(identifier: identifier, metadata: metadata)
    }

    private func makeMetadata(files: [InternetArchiveFile]) -> InternetArchiveMetadata {
        let json: [String: Any] = [
            "metadata": [
                "identifier": "test_item",
                "mediatype": "audio",
                "title": "Test Item"
            ],
            "files": files.map { file in
                [
                    "name": file.name,
                    "source": file.source ?? "original",
                    "format": file.format ?? "",
                    "size": file.size ?? "0"
                ] as [String: String]
            }
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(InternetArchiveMetadata.self, from: data)
    }

    private func makeFile(name: String, format: String, size: String) -> InternetArchiveFile {
        InternetArchiveFile(name: name, source: "original", format: format, size: size)
    }

    private func solidJPEGData(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }
}
