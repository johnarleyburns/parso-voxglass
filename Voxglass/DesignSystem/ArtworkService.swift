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

    static let shared = ArtworkService()

    private let memoryCache = NSCache<NSURL, UIImage>()
    private let cacheDirectory: URL
    private let timeToLive: TimeInterval
    private let fetcher: Fetcher
    private let fileManager: FileManager
    private let ioQueue = DispatchQueue(label: "guru.parso.voxglass.artwork-cache")

    init(
        cacheDirectory: URL? = nil,
        timeToLive: TimeInterval = 60 * 60 * 24 * 14,
        fileManager: FileManager = .default,
        fetcher: Fetcher? = nil
    ) {
        self.fileManager = fileManager
        self.timeToLive = timeToLive
        self.fetcher = fetcher ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            return (data, response)
        }

        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            self.cacheDirectory = fileManager
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoxglassArtwork", isDirectory: true)
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
            return image
        }

        if let image = diskImage(at: cacheURL) {
            memoryCache.setObject(image, forKey: nsURL)
            return image
        }

        let (data, response) = try await fetcher(url)
        let image = try Self.validatedImage(from: data, response: response)
        memoryCache.setObject(image, forKey: nsURL)
        write(data, to: cacheURL)
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
            return image
        }
        return diskImage(at: cacheFileURL(for: url))
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
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
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
