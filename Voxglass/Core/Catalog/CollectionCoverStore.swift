import Combine
import Foundation

/// Resolves a real cover image for every Featured Collection (§3).
///
/// Static hand-typed archive.org identifiers occasionally 404 or resolve to the
/// archive.org "notfound" placeholder. For any such collection we run its
/// `archiveQuery` sorted `downloads desc`, then pick the first item whose
/// artwork actually validates via `ArtworkService`. The resolved
/// `collectionID → identifier` mapping is cached in UserDefaults so covers are
/// stable across launches and don't re-resolve every appearance. The cache is
/// invalidated when the language selection changes, since the top item can
/// differ by language.
@MainActor
final class CollectionCoverStore: ObservableObject {
    @Published private(set) var resolvedCovers: [String: URL] = [:]

    private let client: InternetArchiveCatalogClient
    private let artwork: ArtworkService
    private let defaults: UserDefaults
    private let cacheKey = "voxglass.collectionCoverMap"
    private let languageStampKey = "voxglass.collectionCoverLanguages"
    private var inFlight: Set<String> = []

    init(
        client: InternetArchiveCatalogClient = InternetArchiveClient(),
        artwork: ArtworkService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.artwork = artwork
        self.defaults = defaults
        self.resolvedCovers = Self.loadCache(from: defaults, key: cacheKey)
    }

    func coverURL(for collection: IACollection) -> URL? {
        resolvedCovers[collection.id] ?? collection.remoteImageURL
    }

    /// Resolves covers for the given collections. Skips collections that are
    /// already cached unless `force` is set (used when languages change).
    func resolveCovers(for collections: [IACollection], languages: Set<String>, force: Bool = false) async {
        if force || languageStampChanged(languages) {
            resolvedCovers = [:]
            defaults.removeObject(forKey: cacheKey)
        }
        storeLanguageStamp(languages)

        let languageClause = LibriVoxLanguage.clause(for: languages)
        for collection in collections {
            if resolvedCovers[collection.id] != nil { continue }
            if inFlight.contains(collection.id) { continue }
            inFlight.insert(collection.id)
            await resolve(collection, languageClause: languageClause)
            inFlight.remove(collection.id)
        }
    }

    private func resolve(_ collection: IACollection, languageClause: String) async {
        if let cover = collection.remoteImageURL, await artworkValidates(cover) {
            record(cover, for: collection)
            return
        }

        do {
            let results = try await client.searchAdvanced(query: collection.archiveQuery + languageClause, rows: 12)
            for result in results {
                let cover = result.coverURL
                if await artworkValidates(cover) {
                    record(cover, for: collection)
                    return
                }
            }
        } catch {
            return
        }
    }

    private func artworkValidates(_ url: URL) async -> Bool {
        (try? await artwork.loadImage(for: url)) != nil
    }

    private func record(_ url: URL, for collection: IACollection) {
        resolvedCovers[collection.id] = url
        persist()
    }

    private func persist() {
        let encoded = resolvedCovers.mapValues(\.absoluteString)
        defaults.set(encoded, forKey: cacheKey)
    }

    private func languageStampChanged(_ languages: Set<String>) -> Bool {
        let stored = defaults.string(forKey: languageStampKey)
        return stored != Self.stamp(for: languages)
    }

    private func storeLanguageStamp(_ languages: Set<String>) {
        defaults.set(Self.stamp(for: languages), forKey: languageStampKey)
    }

    private static func stamp(for languages: Set<String>) -> String {
        languages.sorted().joined(separator: ",")
    }

    private static func loadCache(from defaults: UserDefaults, key: String) -> [String: URL] {
        guard let stored = defaults.dictionary(forKey: key) as? [String: String] else { return [:] }
        return stored.compactMapValues(URL.init(string:))
    }
}
