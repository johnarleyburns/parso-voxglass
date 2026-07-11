import CryptoKit
import Foundation
import UIKit

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
        try? await loadImage(for: url)
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

        let prefix = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
        if prefix.contains("notfound") || prefix.contains("not found") {
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

        return image
    }

    static func cacheFileName(for url: URL) -> String {
        cacheKey(for: url)
    }

    /// Stable store key for `url`. The `art_` prefix avoids collisions with audio
    /// cache keys produced by `CachingResourceLoader.key(for:)`.
    static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "art_" + digest.map { String(format: "%02x", $0) }.joined()
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
