import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VoxglassWatchCore

private final class DecodeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(URL, Int)] = []
    func add(_ url: URL, _ size: Int) { lock.lock(); items.append((url, size)); lock.unlock() }
    var all: [(URL, Int)] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite struct WatchArtworkStoreTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJPEG(_ url: URL, side: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: side, height: side * 4 / 3, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side * 4 / 3))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func loadedImage(_ state: WatchArtworkState) -> CGImage? {
        if case .loaded(let image) = state { return image }
        return nil
    }

    @Test func invalidArtworkKeyDoesNotTouchTheFilesystem() async throws {
        let log = DecodeLog()
        let store = WatchArtworkStore(root: try tempRoot()) { url, size in log.add(url, size); return nil }
        for key in [nil, "", "a", "../x/y", "a/../b", "a/b/c", "/a/b", "a\\b/c", "a/"] as [String?] {
            #expect(loadedImage(await store.image(for: key, maxPixelSize: 100)) == nil)
        }
        #expect(log.all.isEmpty)
        #expect(await store.cachedEntryCount == 0)
    }

    @Test func loaderReturnsPlaceholderStateForMissingArtwork() async throws {
        let store = WatchArtworkStore(root: try tempRoot())
        #expect(loadedImage(await store.image(for: "book/cover.jpg", maxPixelSize: 100)) == nil)
    }

    @Test func loaderDecodesOnceAndCachesRepeatedRequestsForTheSameKeyAndSize() async throws {
        let root = try tempRoot()
        try writeJPEG(root.appendingPathComponent("book/cover.jpg"), side: 1500)
        let log = DecodeLog()
        let store = WatchArtworkStore(root: root) { url, size in
            log.add(url, size); return WatchArtworkStore.imageIODecode(url, size)
        }
        let first = await store.image(for: "book/cover.jpg", maxPixelSize: 120)
        let second = await store.image(for: "book/cover.jpg", maxPixelSize: 120)
        #expect(loadedImage(first) != nil && loadedImage(second) != nil)
        #expect(log.all.count == 1)
        // Missing results are cached too.
        _ = await store.image(for: "book/none.jpg", maxPixelSize: 120)
        _ = await store.image(for: "book/none.jpg", maxPixelSize: 120)
        #expect(log.all.count == 2)
    }

    @Test func differentTargetSizesUseAppropriatelyBoundedDecodedImages() async throws {
        let root = try tempRoot()
        try writeJPEG(root.appendingPathComponent("book/cover.jpg"), side: 1500)
        let log = DecodeLog()
        let store = WatchArtworkStore(root: root) { url, size in
            log.add(url, size); return WatchArtworkStore.imageIODecode(url, size)
        }
        let small = loadedImage(await store.image(for: "book/cover.jpg", maxPixelSize: 80))
        let large = loadedImage(await store.image(for: "book/cover.jpg", maxPixelSize: 200))
        #expect(log.all.map(\.1) == [80, 200])
        #expect(max(small!.width, small!.height) <= 80)
        #expect(max(large!.width, large!.height) <= 200)
        #expect(large!.width > small!.width)
        #expect(small!.height > small!.width) // aspect ratio preserved
    }

    @Test func cacheIsBoundedByCount() async throws {
        let store = WatchArtworkStore(root: try tempRoot(), countLimit: 2) { _, _ in nil }
        for i in 0..<5 { _ = await store.image(for: "b\(i)/c.jpg", maxPixelSize: 50) }
        #expect(await store.cachedEntryCount == 2)
        await store.purge()
        #expect(await store.cachedEntryCount == 0)
    }

    @Test func aLaterRequestCannotPublishAnOlderTilesImage() async throws {
        let root = try tempRoot()
        try writeJPEG(root.appendingPathComponent("a/c.jpg"), side: 600)
        try writeJPEG(root.appendingPathComponent("b/c.jpg"), side: 900)
        let store = WatchArtworkStore(root: root)
        // Results are keyed by validated key + size, so each request yields its own image.
        let a = loadedImage(await store.image(for: "a/c.jpg", maxPixelSize: 2000))
        let b = loadedImage(await store.image(for: "b/c.jpg", maxPixelSize: 2000))
        #expect(a?.width == 600 && b?.width == 900)
        let again = loadedImage(await store.image(for: "a/c.jpg", maxPixelSize: 2000))
        #expect(again?.width == 600)
    }

    @Test func watchCoverTileBodyDoesNoSynchronousDiskIO() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("VoxglassWatch/Kit/WatchProgressViews.swift"), encoding: .utf8)
        let tile = String(text[text.range(of: "struct WatchCoverTile")!.lowerBound...])
        #expect(!tile.contains("UIImage(contentsOfFile"))
        #expect(!tile.contains("FileManager.default.fileExists"))
        #expect(tile.contains(".task(id:"))
        #expect(tile.contains("WatchArtworkStore"))
    }
}
