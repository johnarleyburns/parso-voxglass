import Foundation

actor OpusCacheService {
    static let shared = OpusCacheService()

    private var unavailableFiles: Set<String> = []
    private var activeRemuxes: [String: Task<Void, Never>] = [:]

    private var cachesDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("OpusCache", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
    }

    func cachedCAFURL(for remoteURL: URL) -> URL? {
        let cafURL = localCAFURL(for: remoteURL)
        guard FileManager.default.fileExists(atPath: cafURL.path) else { return nil }
        return cafURL
    }

    nonisolated static func cachedCAFURLSync(for remoteURL: URL) -> URL? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("OpusCache", isDirectory: true)
        let key = remoteURL.absoluteString
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let cafURL = dir.appendingPathComponent(key).appendingPathExtension("caf")
        guard FileManager.default.fileExists(atPath: cafURL.path) else { return nil }
        return cafURL
    }

    func isOpusUnavailable(for remoteURL: URL) -> Bool {
        unavailableFiles.contains(cacheKey(for: remoteURL))
    }

    func fetchAndRemux(opusURL: URL, chapterID: String) async -> URL? {
        let key = cacheKey(for: opusURL)

        if let existing = activeRemuxes[key] {
            _ = await existing.value
            return cachedCAFURL(for: opusURL)
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.downloadAndRemux(opusURL: opusURL)
            } catch {
                await self.markUnavailable(opusURL: opusURL)
            }
        }

        activeRemuxes[key] = task
        _ = await task.value
        activeRemuxes[key] = nil

        return cachedCAFURL(for: opusURL)
    }

    func cancelFetch(for remoteURL: URL) {
        let key = cacheKey(for: remoteURL)
        activeRemuxes[key]?.cancel()
        activeRemuxes[key] = nil
    }

    func cacheBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: cachesDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Private

    private func downloadAndRemux(opusURL: URL) async throws -> URL {
        let cafURL = localCAFURL(for: opusURL)

        // Prevent re-remuxing
        if FileManager.default.fileExists(atPath: cafURL.path) {
            return cafURL
        }

        let rawURL = localRawURL(for: opusURL)

        // Download the Opus file
        let session = URLSession.shared
        let (tempURL, _) = try await session.download(from: opusURL)

        // Move to our cache
        try? FileManager.default.removeItem(at: rawURL)
        try FileManager.default.moveItem(at: tempURL, to: rawURL)

        // Remux
        let remuxer = OpusRemuxer()
        let result = try await remuxer.remux(source: rawURL, destination: cafURL)

        // Delete raw Ogg on success
        try? FileManager.default.removeItem(at: rawURL)

        return result.cafURL
    }

    private func markUnavailable(opusURL: URL) {
        unavailableFiles.insert(cacheKey(for: opusURL))
    }

    private func cacheKey(for url: URL) -> String {
        url.absoluteString
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func localCAFURL(for remoteURL: URL) -> URL {
        cachesDirectory.appendingPathComponent(cacheKey(for: remoteURL)).appendingPathExtension("caf")
    }

    private func localRawURL(for remoteURL: URL) -> URL {
        cachesDirectory.appendingPathComponent(cacheKey(for: remoteURL)).appendingPathExtension("opus")
    }
}
