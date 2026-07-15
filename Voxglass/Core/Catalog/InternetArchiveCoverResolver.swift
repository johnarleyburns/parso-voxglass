import Foundation

actor InternetArchiveCoverResolver {
    static let shared = InternetArchiveCoverResolver()

    private var cache: [String: URL?] = [:]

    /// Validates that a resolved cover URL loads a real image. Injected by the app
    /// (the concrete check needs UIKit); when unset (e.g. host tests) resolution
    /// treats covers as unvalidated.
    private var artworkValidator: CoverArtworkValidating?

    func setArtworkValidator(_ validator: CoverArtworkValidating) {
        artworkValidator = validator
    }

    func resolve(for identifier: String) async -> URL? {
        if let cached = cache[identifier] {
            return cached
        }

        let primaryURL = InternetArchiveMetadata.coverURL(for: identifier)

        if await artworkValidates(primaryURL) {
            cache[identifier] = primaryURL
            return primaryURL
        }

        if let fallbackURL = await resolveFromMetadata(identifier: identifier) {
            cache[identifier] = fallbackURL
            return fallbackURL
        }

        cache[identifier] = Optional<URL>.none
        return nil
    }

    func clearCache() {
        cache.removeAll()
    }

    private func artworkValidates(_ url: URL) async -> Bool {
        await artworkValidator?.imageValidates(at: url) ?? false
    }

    private func resolveFromMetadata(identifier: String) async -> URL? {
        guard let url = Self.metadataURL(for: identifier) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return nil
            }
            let metadata = try JSONDecoder().decode(InternetArchiveMetadata.self, from: data)
            for file in metadata.coverImageFiles.prefix(3) {
                if let fileURL = metadata.fileURL(for: file) {
                    return fileURL
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func metadataURL(for identifier: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "archive.org"
        components.path = "/metadata/\(identifier)"
        components.queryItems = [URLQueryItem(name: "extended_err", value: "1")]
        return components.url
    }
}
