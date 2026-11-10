import CoreGraphics
import Foundation
import ImageIO

/// What a Watch cover tile renders. `placeholder` is the existing gold tile.
public enum WatchArtworkState: Sendable {
    case placeholder
    case loaded(CGImage)
}

/// Asynchronous, bounded artwork pipeline for Watch cover tiles.
/// Keys are validated before any filesystem access; decoding happens inside
/// this actor (never on the MainActor) and is downsampled to the requested bounds.
public actor WatchArtworkStore {
    public typealias Decoder = @Sendable (_ url: URL, _ maxPixelSize: Int) -> CGImage?

    private struct CacheKey: Hashable { let artworkKey: String; let maxPixelSize: Int }
    private enum Entry { case image(CGImage), missing }

    private let root: URL
    private let decode: Decoder
    private let countLimit: Int
    private var cache: [CacheKey: Entry] = [:]
    private var order: [CacheKey] = []
    private var inFlight: [CacheKey: Task<CGImage?, Never>] = [:]

    public init(root: URL, countLimit: Int = 48, decode: @escaping Decoder = WatchArtworkStore.imageIODecode) {
        self.root = root
        self.countLimit = max(1, countLimit)
        self.decode = decode
    }

    /// Returns nil when the key is not a safe `<book>/<file>` pair.
    public static func validatedKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(WatchPhonePushFiles.safeComponent) else { return nil }
        return key
    }

    public func image(for artworkKey: String?, maxPixelSize: Int) async -> WatchArtworkState {
        guard let key = Self.validatedKey(artworkKey), maxPixelSize > 0 else { return .placeholder }
        let cacheKey = CacheKey(artworkKey: key, maxPixelSize: maxPixelSize)
        if let hit = cache[cacheKey] {
            touch(cacheKey)
            if case .image(let image) = hit { return .loaded(image) }
            return .placeholder
        }
        let task: Task<CGImage?, Never>
        if let running = inFlight[cacheKey] {
            task = running
        } else {
            let url = root.appendingPathComponent(key)
            let decode = self.decode
            task = Task.detached(priority: .utility) { decode(url, maxPixelSize) }
            inFlight[cacheKey] = task
        }
        let result = await task.value
        inFlight[cacheKey] = nil
        store(result.map(Entry.image) ?? .missing, for: cacheKey)
        return result.map(WatchArtworkState.loaded) ?? .placeholder
    }

    /// Drop everything (memory pressure) or only missing-file results (new download installed).
    public func purge(missingOnly: Bool = false) {
        if missingOnly {
            for (key, entry) in cache { if case .missing = entry { cache[key] = nil } }
            order.removeAll { cache[$0] == nil }
        } else {
            cache.removeAll(); order.removeAll()
        }
    }

    public var cachedEntryCount: Int { cache.count }

    private func touch(_ key: CacheKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func store(_ entry: Entry, for key: CacheKey) {
        cache[key] = entry
        touch(key)
        while order.count > countLimit {
            cache[order.removeFirst()] = nil
        }
    }

    /// ImageIO thumbnailing: decodes at the bounded size, preserving aspect ratio.
    public static let imageIODecode: Decoder = { url, maxPixelSize in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
