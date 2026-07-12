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

    /// Approximate, cached "N books" total per collection (live IA `numFound`).
    /// Refreshed only when the language selection changes; each query uses
    /// `rows: 0` so it's cheap.
    @Published private(set) var counts: [String: Int] = [:]

    private let client: InternetArchiveCatalogClient
    private let artwork: ArtworkService
    private let defaults: UserDefaults
    private let cacheKey = "voxglass.collectionCoverMap"
    private let languageStampKey = "voxglass.collectionCoverLanguages"
    private let countsCacheKey = "voxglass.collectionCountMap"
    private let countsLanguageStampKey = "voxglass.collectionCountLanguages"
    private var inFlight: Set<String> = []
    private var countsInFlight: Set<String> = []

    init(
        client: InternetArchiveCatalogClient = InternetArchiveClient(),
        artwork: ArtworkService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.artwork = artwork
        self.defaults = defaults
        self.resolvedCovers = Self.loadCache(from: defaults, key: cacheKey)
        self.counts = Self.loadCounts(from: defaults, key: countsCacheKey)
    }

    func coverURL(for collection: IACollection) -> URL? {
        resolvedCovers[collection.id] ?? collection.remoteImageURL
    }

    func count(for collection: IACollection) -> Int? {
        counts[collection.id]
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

    /// Resolves an approximate book count for each collection using the live IA
    /// total (`numFound`). Cached per collection + language stamp; only refreshed
    /// when the language selection changes. `rows: 0` keeps each query cheap.
    func resolveCounts(for collections: [IACollection], languages: Set<String>, force: Bool = false) async {
        if force || countsLanguageStampChanged(languages) {
            counts = [:]
            defaults.removeObject(forKey: countsCacheKey)
        }
        storeCountsLanguageStamp(languages)

        let languageClause = LibriVoxLanguage.clause(for: languages)
        for collection in collections {
            if counts[collection.id] != nil { continue }
            if countsInFlight.contains(collection.id) { continue }
            countsInFlight.insert(collection.id)
            await resolveCount(collection, languageClause: languageClause)
            countsInFlight.remove(collection.id)
        }
    }

    private func resolveCount(_ collection: IACollection, languageClause: String) async {
        do {
            let page = try await client.searchAdvancedPage(
                query: collection.archiveQuery + languageClause,
                rows: 0,
                page: 1
            )
            counts[collection.id] = page.numFound
            persistCounts()
        } catch {
            return
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

    private func persistCounts() {
        defaults.set(counts, forKey: countsCacheKey)
    }

    private func languageStampChanged(_ languages: Set<String>) -> Bool {
        let stored = defaults.string(forKey: languageStampKey)
        return stored != Self.stamp(for: languages)
    }

    private func storeLanguageStamp(_ languages: Set<String>) {
        defaults.set(Self.stamp(for: languages), forKey: languageStampKey)
    }

    private func countsLanguageStampChanged(_ languages: Set<String>) -> Bool {
        let stored = defaults.string(forKey: countsLanguageStampKey)
        return stored != Self.stamp(for: languages)
    }

    private func storeCountsLanguageStamp(_ languages: Set<String>) {
        defaults.set(Self.stamp(for: languages), forKey: countsLanguageStampKey)
    }

    private static func stamp(for languages: Set<String>) -> String {
        languages.sorted().joined(separator: ",")
    }

    private static func loadCache(from defaults: UserDefaults, key: String) -> [String: URL] {
        guard let stored = defaults.dictionary(forKey: key) as? [String: String] else { return [:] }
        return stored.compactMapValues(URL.init(string:))
    }

    private static func loadCounts(from defaults: UserDefaults, key: String) -> [String: Int] {
        (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }
}
