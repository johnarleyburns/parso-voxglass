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
