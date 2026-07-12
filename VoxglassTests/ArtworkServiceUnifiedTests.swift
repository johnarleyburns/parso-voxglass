import UIKit
import XCTest
@testable import Voxglass

final class ArtworkServiceUnifiedTests: XCTestCase {
    @MainActor
    func testDiskWriteRegistersArtworkBytesWithStore() async throws {
        let (service, spy, url, data) = try makeService()

        _ = try await service.loadImage(for: url)

        XCTAssertEqual(spy.registered.count, 1)
        XCTAssertEqual(spy.registered.first?.key, ArtworkService.cacheKey(for: url))
        XCTAssertEqual(spy.registered.first?.bytes, Int64(data.count))
    }

    @MainActor
    func testCacheHitTouchesStoreKey() async throws {
        let (service, spy, url, _) = try makeService()

        _ = try await service.loadImage(for: url)   // populates memory + registers
        spy.reset()

        _ = try await service.loadImage(for: url)    // memory hit -> touch
        _ = service.cachedImage(for: url)            // fast path -> touch

        XCTAssertTrue(spy.touched.contains(ArtworkService.cacheKey(for: url)))
        XCTAssertGreaterThanOrEqual(spy.touched.count, 2)
        XCTAssertTrue(spy.registered.isEmpty, "Cache hits must not re-register bytes")
    }

    // MARK: - §4 IA "temple facade" placeholder rejection

    func testRejectsInternetArchiveNotFoundRedirectByFinalURL() throws {
        let finalURL = URL(string: "https://archive.org/images/notfound2x.png")!
        let response = HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        let data = try exactPixelPNG(width: 320, height: 220)

        XCTAssertThrowsError(try ArtworkService.validatedImage(from: data, response: response)) { error in
            XCTAssertEqual(error as? ArtworkServiceError, .notFoundImage)
        }
    }

    func testRejectsTempleFacadePlaceholderBySignature() throws {
        let servedURL = URL(string: "https://archive.org/services/img/coverless_item")!
        let response = HTTPURLResponse(url: servedURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        let data = try exactPixelPNG(width: 320, height: 220)

        XCTAssertThrowsError(try ArtworkService.validatedImage(from: data, response: response)) { error in
            XCTAssertEqual(error as? ArtworkServiceError, .notFoundImage)
        }
    }

    func testAcceptsRealSquareCoverFromServicesImg() throws {
        let servedURL = URL(string: "https://archive.org/services/img/prideandprejudice_1005_librivox")!
        let response = HTTPURLResponse(url: servedURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        let data = try noisyImageData(width: 180, height: 180)
        XCTAssertGreaterThanOrEqual(data.count, 8_000, "Test cover must exceed the placeholder byte threshold")

        XCTAssertNoThrow(try ArtworkService.validatedImage(from: data, response: response))
    }

    private func makeService() throws -> (ArtworkService, HookSpy, URL, Data) {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-artwork-unified-\(UUID().uuidString)", isDirectory: true)
        let url = URL(string: "https://archive.org/services/img/unified_test_item")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = try pngData(width: 48, height: 72)
        let fetchBox = FetchBoxUnified(data: data, response: response)
        let spy = HookSpy()
        let service = ArtworkService(
            cacheDirectory: tempDirectory,
            timeToLive: 60,
            fetcher: fetchBox.fetch,
            registerBytes: spy.register,
            touchKey: spy.touch
        )
        return (service, spy, url, data)
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }

    /// A solid image whose *encoded* pixel dimensions equal `width` x `height`
    /// (scale locked to 1), so placeholder-signature checks can be exercised.
    private func exactPixelPNG(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }

    /// A high-entropy image whose PNG encoding comfortably exceeds the 8 KB
    /// placeholder threshold, standing in for a real cover.
    private func noisyImageData(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        var generator = SystemRandomNumberGenerator()
        let image = renderer.image { context in
            for y in 0..<height {
                for x in 0..<width {
                    UIColor(
                        red: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        green: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        blue: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return try XCTUnwrap(image.pngData())
    }
}

private final class HookSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _registered: [(key: String, bytes: Int64)] = []
    private var _touched: [String] = []

    var registered: [(key: String, bytes: Int64)] {
        lock.lock(); defer { lock.unlock() }; return _registered
    }
    var touched: [String] {
        lock.lock(); defer { lock.unlock() }; return _touched
    }

    lazy var register: @Sendable (String, Int64) -> Void = { [weak self] key, bytes in
        guard let self else { return }
        self.lock.lock(); self._registered.append((key, bytes)); self.lock.unlock()
    }

    lazy var touch: @Sendable (String) -> Void = { [weak self] key in
        guard let self else { return }
        self.lock.lock(); self._touched.append(key); self.lock.unlock()
    }

    func reset() {
        lock.lock(); _registered.removeAll(); _touched.removeAll(); lock.unlock()
    }
}

private final class FetchBoxUnified: @unchecked Sendable {
    let data: Data
    let response: URLResponse

    init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }

    func fetch(_ url: URL) async throws -> (Data, URLResponse?) {
        (data, response)
    }
}
