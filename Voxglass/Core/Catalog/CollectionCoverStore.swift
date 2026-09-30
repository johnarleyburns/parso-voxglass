import Combine
import Foundation

public struct CollectionBookPreview: Codable, Equatable, Sendable {
    public let title: String
    public let author: String

    public init(title: String, author: String) {
        self.title = title
        self.author = author
    }
}

/// Resolves a real cover image for every Featured Collection (§3).
///
/// Static hand-typed archive.org identifiers can drift away from the live
/// collection results. Discover therefore resolves artwork from each collection's
/// own visible query sorted by popularity, then caches the winning
/// `collectionID -> itemIdentifier` with a language/query stamp.
@MainActor
public final class CollectionCoverStore: ObservableObject {
    @Published public private(set) var resolvedCovers: [String: URL] = [:]
    @Published public private(set) var resolvedPreviews: [String: [CollectionBookPreview]] = [:]

    /// Approximate, cached "N books" total per collection (live IA `numFound`).
    /// Refreshed only when the language selection changes; each query uses
    /// `rows: 0` so it's cheap.
    @Published public private(set) var counts: [String: Int] = [:]

    private let client: InternetArchiveCatalogClient
    private let artwork: CoverArtworkValidating
    private let defaults: UserDefaults
    private let coverIdentifierCacheKey = "voxglass.collectionCoverIdentifierMap.v3"
    private let coverStampCacheKey = "voxglass.collectionCoverStampMap.v3"
    private let previewCacheKey = "voxglass.collectionBookPreviewMap.v1"
    private let countsCacheKey = "voxglass.collectionCountMap.v3"
    private let countsStampCacheKey = "voxglass.collectionCountStampMap.v3"
    private var resolvedIdentifiers: [String: String]
    private var coverStamps: [String: String]
    private var countStamps: [String: String]
    private var inFlight: Set<String> = []
    private var countsInFlight: Set<String> = []

    public init(
        client: InternetArchiveCatalogClient = InternetArchiveClient(),
        artwork: CoverArtworkValidating,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.artwork = artwork
        self.defaults = defaults
        let identifiers = Self.loadStringMap(from: defaults, key: coverIdentifierCacheKey)
        self.resolvedIdentifiers = identifiers
        self.resolvedCovers = identifiers.mapValues {
            InternetArchiveMetadata.coverURL(for: $0)
        }
        self.resolvedPreviews = Self.loadPreviews(from: defaults, key: previewCacheKey)
        self.coverStamps = Self.loadStringMap(from: defaults, key: coverStampCacheKey)
        self.counts = Self.loadCounts(from: defaults, key: countsCacheKey)
        self.countStamps = Self.loadStringMap(from: defaults, key: countsStampCacheKey)
    }

    public func coverURL(for collection: IACollection) -> URL? {
        resolvedCovers[collection.id]
    }

    public func count(for collection: IACollection) -> Int? {
        counts[collection.id]
    }

    public func previews(for collection: IACollection) -> [CollectionBookPreview] {
        resolvedPreviews[collection.id] ?? []
    }

    /// Resolves covers for the given collections. Skips collections that are
    /// already cached unless `force` is set (used when languages change).
    public func resolveCovers(for collections: [IACollection], languages: Set<String>, force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for collection in collections {
                group.addTask { [weak self] in
                    await self?.resolveCoverIfNeeded(
                        for: collection,
                        languages: languages,
                        force: force
                    )
                }
            }
        }
    }

    private func resolveCoverIfNeeded(
        for collection: IACollection,
        languages: Set<String>,
        force: Bool
    ) async {
        let stamp = Self.stamp(for: languages, query: collection.archiveQuery)
        if force || coverStamps[collection.id] != stamp {
            resolvedIdentifiers[collection.id] = nil
            resolvedCovers[collection.id] = nil
            coverStamps[collection.id] = stamp
            persistCoverIdentifiers()
            persistCoverStamps()
        }
        if resolvedCovers[collection.id] != nil, !resolvedPreviews[collection.id, default: []].isEmpty { return }
        if inFlight.contains(collection.id) { return }
        inFlight.insert(collection.id)
        await resolve(collection, languages: languages, stamp: stamp)
        inFlight.remove(collection.id)
    }

    /// Resolves an approximate book count for each collection using the live IA
    /// total (`numFound`). Cached per collection + language stamp; only refreshed
    /// when the language selection changes. `rows: 0` keeps each query cheap.
    public func resolveCounts(for collections: [IACollection], languages: Set<String>, force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for collection in collections {
                group.addTask { [weak self] in
                    await self?.resolveCountIfNeeded(
                        for: collection,
                        languages: languages,
                        force: force
                    )
                }
            }
        }
    }

    private func resolveCountIfNeeded(
        for collection: IACollection,
        languages: Set<String>,
        force: Bool
    ) async {
        let stamp = Self.stamp(for: languages, query: collection.archiveQuery)
        if force || countStamps[collection.id] != stamp {
            counts[collection.id] = nil
            countStamps[collection.id] = stamp
            persistCounts()
            persistCountStamps()
        }
        if counts[collection.id] != nil { return }
        if languages == CollectionBundledCounts.languages {
            if collection.isCurated, let curatedName = collection.curatedListName {
                counts[collection.id] = CuratedManifest.load(named: curatedName).count
            } else if let bundled = CollectionBundledCounts.counts[collection.id] {
                counts[collection.id] = bundled
            }
            if counts[collection.id] != nil {
                countStamps[collection.id] = stamp
                persistCounts()
                persistCountStamps()
                return
            }
        }
        if countsInFlight.contains(collection.id) { return }
        countsInFlight.insert(collection.id)
        await resolveCount(collection, languages: languages, stamp: stamp)
        countsInFlight.remove(collection.id)
    }

    private func resolveCount(_ collection: IACollection, languages: Set<String>, stamp: String) async {
        do {
            let query = collection.archiveQuery + LibriVoxLanguage.clause(for: languages)
            let page = try await client.searchAdvancedPage(
                query: query,
                rows: 0,
                page: 1,
                sort: .popularity
            )
            counts[collection.id] = page.numFound
            countStamps[collection.id] = stamp
            persistCounts()
            persistCountStamps()
        } catch {
            return
        }
    }

    private func resolve(_ collection: IACollection, languages: Set<String>, stamp: String) async {
        do {
            let query = collection.archiveQuery + LibriVoxLanguage.clause(for: languages)
            let results = try await client.searchAdvanced(query: query, rows: 12, sort: .popularity)
            resolvedPreviews[collection.id] = results.prefix(3).map {
                CollectionBookPreview(title: $0.title, author: $0.displayAuthorLine ?? "")
            }
            persistPreviews()
            for result in results {
                let cover = result.coverURL
                if await artworkValidates(cover) {
                    record(result.identifier, stamp: stamp, for: collection)
                    return
                }
            }
        } catch {
            return
        }
    }

    private func artworkValidates(_ url: URL) async -> Bool {
        await artwork.imageValidates(at: url)
    }

    private func record(_ identifier: String, stamp: String, for collection: IACollection) {
        resolvedIdentifiers[collection.id] = identifier
        resolvedCovers[collection.id] = InternetArchiveMetadata.coverURL(for: identifier)
        coverStamps[collection.id] = stamp
        persistCoverIdentifiers()
        persistCoverStamps()
    }

    private func persistCoverIdentifiers() {
        defaults.set(resolvedIdentifiers, forKey: coverIdentifierCacheKey)
    }

    private func persistPreviews() {
        guard let data = try? JSONEncoder().encode(resolvedPreviews) else { return }
        defaults.set(data, forKey: previewCacheKey)
    }

    private func persistCounts() {
        defaults.set(counts, forKey: countsCacheKey)
    }

    private func persistCoverStamps() {
        defaults.set(coverStamps, forKey: coverStampCacheKey)
    }

    private func persistCountStamps() {
        defaults.set(countStamps, forKey: countsStampCacheKey)
    }

    private static func stamp(for languages: Set<String>, query: String) -> String {
        "\(languages.sorted().joined(separator: ","))|\(query)"
    }

    private static func loadStringMap(from defaults: UserDefaults, key: String) -> [String: String] {
        (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    private static func loadCounts(from defaults: UserDefaults, key: String) -> [String: Int] {
        (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    private static func loadPreviews(
        from defaults: UserDefaults,
        key: String
    ) -> [String: [CollectionBookPreview]] {
        guard let data = defaults.data(forKey: key),
              let previews = try? JSONDecoder().decode(
                  [String: [CollectionBookPreview]].self,
                  from: data
              ) else { return [:] }
        return previews
    }
}
