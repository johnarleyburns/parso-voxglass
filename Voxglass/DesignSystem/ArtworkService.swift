import CryptoKit
import Foundation
import UIKit
import VoxglassCore

enum ArtworkServiceError: Error, Equatable {
    case invalidHTTPStatus(Int)
    case notFoundImage
    case tinyImage
    case undecodableImage
}

final class ArtworkService: @unchecked Sendable {
    typealias Fetcher = @Sendable (URL) async throws -> (Data, URLResponse?)
    typealias RegisterHook = @Sendable (String, Int64) -> Void
    typealias TouchHook = @Sendable (String) -> Void

    static let shared = ArtworkService()

    private let memoryCache = NSCache<NSURL, UIImage>()
    private let cacheDirectory: URL
    private let timeToLive: TimeInterval
    private let fetcher: Fetcher
    private let fileManager: FileManager
    private let registerBytes: RegisterHook
    private let touchKey: TouchHook
    private let ioQueue = DispatchQueue(label: "guru.parso.voxglass.artwork-cache")

    init(
        cacheDirectory: URL? = nil,
        timeToLive: TimeInterval = 60 * 60 * 24 * 14,
        fileManager: FileManager = .default,
        fetcher: Fetcher? = nil,
        registerBytes: RegisterHook? = nil,
        touchKey: TouchHook? = nil
    ) {
        self.fileManager = fileManager
        self.timeToLive = timeToLive
        self.fetcher = fetcher ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            return (data, response)
        }
        self.registerBytes = registerBytes ?? { key, bytes in
            Task { await StreamCacheStore.shared.registerArtwork(key: key, bytes: bytes) }
        }
        self.touchKey = touchKey ?? { key in
            Task { await StreamCacheStore.shared.touch(key) }
        }

        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            self.cacheDirectory = StreamCacheStore.defaultArtworkDirectory
        }

        ioQueue.sync {
            try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        }
    }

    func image(for url: URL) async -> UIImage? {
        if let image = try? await loadImage(for: url) {
            return image
        }
        guard let identifier = Self.extractIAIdentifier(from: url),
              let resolvedURL = await InternetArchiveCoverResolver.shared.resolve(for: identifier),
              resolvedURL != url else {
            return nil
        }
        return try? await loadImage(for: resolvedURL)
    }

    func loadImage(for url: URL) async throws -> UIImage {
        let cacheURL = cacheFileURL(for: url)
        let nsURL = url as NSURL

        if let image = memoryCache.object(forKey: nsURL) {
            touchKey(cacheKey(url))
            return image
        }

        if let image = diskImage(at: cacheURL) {
            memoryCache.setObject(image, forKey: nsURL)
            touchKey(cacheKey(url))
            return image
        }

        let (data, response) = try await fetcher(url)
        let image = try Self.validatedImage(from: data, response: response)
        memoryCache.setObject(image, forKey: nsURL)
        write(data, to: cacheURL)
        registerBytes(cacheKey(url), Int64(data.count))
        return image
    }

    func prefetch(urls: [URL], limit: Int = 16) {
        let uniqueURLs = Array(Set(urls)).prefix(limit)
        guard !uniqueURLs.isEmpty else { return }

        Task.detached(priority: .background) { [self] in
            for url in uniqueURLs {
                _ = try? await loadImage(for: url)
            }
        }
    }

    func cachedImage(for url: URL) -> UIImage? {
        if let image = memoryCache.object(forKey: url as NSURL) {
            touchKey(cacheKey(url))
            return image
        }
        if let image = diskImage(at: cacheFileURL(for: url)) {
            touchKey(cacheKey(url))
            return image
        }
        return nil
    }

    /// Empties the in-memory tier for the Settings "Clear Cache" path.
    /// Disk artwork is wiped by `StreamCacheStore.clearAll()`.
    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    static func validatedImage(from data: Data, response: URLResponse?) throws -> UIImage {
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ArtworkServiceError.invalidHTTPStatus(httpResponse.statusCode)
        }

        // Reject the Internet Archive not-found placeholder (the classical
        // "temple facade" logo). For coverless items IA 302-redirects
        // services/img/<id> to /images/notfound.png (160x110) or
        // /images/notfound2x.png (320x220); the final URL after redirects is the
        // most reliable signal since the 2x asset is larger than the size
        // heuristics below catch.
        if let finalURL = response?.url, Self.isInternetArchiveNotFoundAsset(finalURL) {
            throw ArtworkServiceError.notFoundImage
        }

        // Reject non-image Content-Type (text/html is a common IA error page)
        if let mime = (response as? HTTPURLResponse)?.mimeType?.lowercased(),
           !mime.hasPrefix("image/") {
            throw ArtworkServiceError.notFoundImage
        }

        let prefix = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
        if prefix.contains("notfound") || prefix.contains("not found") {
            throw ArtworkServiceError.notFoundImage
        }

        // Check for HTML error pages before trying to decode as image
        if prefix.contains("<!doctype") || prefix.contains("<html") {
            throw ArtworkServiceError.notFoundImage
        }

        guard let image = UIImage(data: data) else {
            throw ArtworkServiceError.undecodableImage
        }

        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        if pixelWidth < 24 || pixelHeight < 24 {
            throw ArtworkServiceError.tinyImage
        }

        // Reject known Internet Archive placeholder images — these are generic
        // "no cover" images served when an item has no real cover. They are
        // typically small square images with specific dimensions.
        if isIAUnwantedPlaceholder(image: image, dataCount: data.count) {
            throw ArtworkServiceError.notFoundImage
        }

        return image
    }

    private static func isIAUnwantedPlaceholder(image: UIImage, dataCount: Int) -> Bool {
        let px = Int(image.size.width * image.scale)
        let py = Int(image.size.height * image.scale)
        // IA serves several generic placeholders: the "open book" icon (~180x180),
        // the "microphone" icon, and a few others. With ?scale=2, real covers
        // come back at 360x360 or larger and are well above 8 KB, so a small
        // low-detail image remains a strong placeholder signal.
        if px <= 200 && py <= 200 && dataCount < 1_000 {
            return true
        }
        // The Internet Archive "temple facade" not-found logo served at 2x
        // (/images/notfound2x.png) is 320x220 and ~3.8 KB — larger than the
        // rule above, but its distinctive non-square dimensions plus tiny byte
        // size never match a real cover (which comes back square from
        // services/img).
        if px == 320 && py == 220 && dataCount < 5_000 {
            return true
        }
        // Reject the 120x120 placeholder square. Real covers are returned at
        // 180x180 by services/img, so we must NOT reject that size here.
        if px == 120 && py == 120 {
            return true
        }
        return false
    }

    /// True when `url` points at an Internet Archive not-found asset
    /// (`/images/notfound.png` or `/images/notfound2x.png`) — the destination of
    /// a services/img redirect for a coverless item.
    private static func isInternetArchiveNotFoundAsset(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host.hasSuffix("archive.org") else { return false }
        return url.lastPathComponent.lowercased().hasPrefix("notfound")
    }

    static func extractIAIdentifier(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host.hasSuffix("archive.org"),
              url.path.hasPrefix("/services/img/") else {
            return nil
        }
        let identifier = url.lastPathComponent
        guard !identifier.isEmpty, !identifier.hasPrefix("notfound") else { return nil }
        return identifier
    }

    static func cacheFileName(for url: URL) -> String {
        ArtworkCacheKey.fileName(for: url)
    }

    /// Stable store key for `url`. Delegates to Core's `ArtworkCacheKey` so the
    /// library layer and this service derive identical keys (single source).
    static func cacheKey(for url: URL) -> String {
        ArtworkCacheKey.key(for: url)
    }

    private func cacheKey(_ url: URL) -> String {
        Self.cacheKey(for: url)
    }

    private func cacheFileURL(for url: URL) -> URL {
        cacheDirectory.appendingPathComponent(Self.cacheFileName(for: url), isDirectory: false)
    }

    private func diskImage(at url: URL) -> UIImage? {
        ioQueue.sync {
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                let modificationDate = attributes[.modificationDate] as? Date,
                Date().timeIntervalSince(modificationDate) <= timeToLive,
                let data = try? Data(contentsOf: url),
                let image = UIImage(data: data)
            else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            return image
        }
    }

    private func write(_ data: Data, to url: URL) {
        ioQueue.async { [fileManager] in
            try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }
}

extension ArtworkService: CoverArtworkValidating {
    /// Core's cover-resolution seam: an image "validates" when it decodes to a
    /// real (non-placeholder) cover, which `loadImage(for:)` enforces.
    func imageValidates(at url: URL) async -> Bool {
        (try? await loadImage(for: url)) != nil
    }
}
