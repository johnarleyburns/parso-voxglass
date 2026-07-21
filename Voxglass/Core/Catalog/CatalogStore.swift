import Combine
import Foundation

@MainActor
public final class CatalogStore: ObservableObject {
    @Published public private(set) var results: [InternetArchiveSearchResult] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var isResolvingURL = false
    @Published public private(set) var hasMore = false
    @Published public var catalogError: String?

    /// Batch-download state for curated collections.
    @Published public var batchProgress: (completed: Int, total: Int)? = nil
    @Published public var isBatchDownloading = false

    /// The user's search text, promoted to the store so it survives `SearchView`
    /// being recreated on tab changes (§3). `SearchView` binds its field to this.
    @Published public var query: String = ""

    /// Languages the user has selected (see §1). Kept in sync from
    /// `AppPreferencesStore`; injected centrally into every catalog query so
    /// language filtering is applied in exactly one place.
    public var selectedLanguages: Set<String> = LibriVoxLanguage.defaultSelection {
        didSet {
            guard oldValue != selectedLanguages else { return }
            reloadForLanguageChange()
        }
    }

    private let client: InternetArchiveCatalogClient
    private let pageSize = 25
    private var activeQuery: String?
    private var activeCollectionID: String?
    private var activeSort: CatalogSort = .popularity
    private var currentPage = 1
    private var numFound = 0
    private var seenIdentifiers: Set<String> = []
    private var chainFetchCount = 0
    private var curatedManifest: [CuratedManifestEntry] = []

    public init(client: InternetArchiveCatalogClient = InternetArchiveClient()) {
        self.client = client
    }

    private var languageClause: String {
        LibriVoxLanguage.clause(for: selectedLanguages)
    }

    public func searchLibriVox(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed
        guard !trimmed.isEmpty else {
            resetResults()
            return
        }
        await runSearch(query: InternetArchiveClient.libriVoxQuery(for: trimmed) + languageClause, sort: .popularity)
    }

    public func searchAdvanced(_ query: String, sort: CatalogSort = .popularity, collectionID: String? = nil) async {
        activeCollectionID = collectionID
        curatedManifest = []
        if sort == .curation, let id = collectionID,
           let collection = IACollectionStore.allSelectableCollections.first(where: { $0.id == id }),
           let curatedName = collection.curatedListName {
            curatedManifest = CuratedManifest.load(named: curatedName)
        }
        if sort == .curation {
            await runCurationSearch()
        } else {
            await runSearch(query: query + languageClause, sort: sort)
        }
    }

    public func loadMore() async {
        guard hasMore, !isSearching, !isLoadingMore else { return }
        if activeSort == .curation {
            await loadMoreCuration()
            return
        }
        guard let query = activeQuery else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let nextPage = currentPage + 1
        do {
            let page = try await client.searchAdvancedPage(
                query: query,
                rows: pageSize,
                page: nextPage,
                sort: activeSort
            )
            currentPage = nextPage
            numFound = page.numFound
            let appended = filteredResults(page.results, for: query)
                .filter { seenIdentifiers.insert($0.identifier).inserted }
            results.append(contentsOf: appended)
            updateHasMore()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func runCurationSearch() async {
        isSearching = true
        defer { isSearching = false }

        activeSort = .curation
        currentPage = 1
        numFound = curatedManifest.count

        let slice = CuratedPager.slice(manifest: curatedManifest, page: 1, size: pageSize)
        guard !slice.isEmpty else {
            results = []
            seenIdentifiers = []
            updateHasMore()
            return
        }
        let identifierQuery = buildIdentifierQuery(from: slice)

        do {
            let page = try await client.searchAdvancedPage(query: identifierQuery, rows: pageSize, page: 1, sort: .popularity)
            seenIdentifiers = []
            let ordered = CuratedPager.order(results: page.results, by: slice)
            let filtered = filteredResults(ordered, for: identifierQuery)
                .filter { seenIdentifiers.insert($0.identifier).inserted }
            results = filtered
            updateHasMore()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func loadMoreCuration() async {
        isLoadingMore = true
        defer { isLoadingMore = false }

        let nextPage = currentPage + 1
        let slice = CuratedPager.slice(manifest: curatedManifest, page: nextPage, size: pageSize)
        guard !slice.isEmpty else {
            updateHasMore()
            return
        }
        let identifierQuery = buildIdentifierQuery(from: slice)

        do {
            let page = try await client.searchAdvancedPage(query: identifierQuery, rows: pageSize, page: 1, sort: .popularity)
            currentPage = nextPage
            let ordered = CuratedPager.order(results: page.results, by: slice)
            let appended = ordered.filter { seenIdentifiers.insert($0.identifier).inserted }
            results.append(contentsOf: appended)
            updateHasMore()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func buildIdentifierQuery(from slice: [CuratedManifestEntry]) -> String {
        let identifiers = slice.map { "identifier:\"\($0.identifier)\"" }
        return "mediatype:audio AND (\(identifiers.joined(separator: " OR ")))"
    }

    public func importResult(
        _ result: InternetArchiveSearchResult,
        into libraryStore: LibraryStore
    ) async -> BookWithChapters? {
        do {
            return try await CatalogResultImporter.importResult(result, into: libraryStore, using: client)
        } catch {
            catalogError = CatalogResultImporter.importErrorMessage(for: result, underlying: error)
            return nil
        }
    }

    public func addArchiveURL(
        _ rawValue: String,
        into libraryStore: LibraryStore
    ) async -> BookWithChapters? {
        guard let resource = InternetArchiveURLParser.parse(rawValue) else {
            catalogError = InternetArchiveError.unsupportedURL.localizedDescription
            return nil
        }

        isResolvingURL = true
        defer { isResolvingURL = false }

        do {
            switch resource {
            case .advancedSearch(let query):
                await runSearch(query: query + languageClause, sort: .popularity)
                return nil
            case .identifier(let identifier):
                let metadata = try await client.metadata(for: identifier)
                if metadata.isCollection {
                    results = try await client.searchCollection(identifier: identifier)
                    resetPaging()
                    return nil
                }

                let sourceKind: SourceKind = metadata.sourceKind == .librivox ? .librivox : .internetArchiveURL
                return await libraryStore.importInternetArchiveItem(metadata, sourceKind: sourceKind)
            }
        } catch {
            catalogError = error.localizedDescription
            return nil
        }
    }

    /// Exposes the currently loaded curated manifest so "Download All" can
    /// drive batch imports from the manifest entries rather than the paged results.
    public var activeCuratedManifest: [CuratedManifestEntry] {
        curatedManifest
    }

    /// Estimated total download size for a curated collection, in bytes.
    /// Uses a conservative average of ~250 MB per LibriVox audiobook (MP3).
    public static func estimatedBatchSize(entryCount: Int) -> Int64 {
        Int64(entryCount) * 250_000_000
    }

    public static func formattedBatchSize(entryCount: Int) -> String {
        let bytes = estimatedBatchSize(entryCount: entryCount)
        let gb = Double(bytes) / 1_000_000_000.0
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000.0)
    }

    /// Downloads and imports all items in the curated collection.
    /// - Parameter libraryStore: The library to import items into.
    /// Skips items that fail metadata fetch and continues.
    public func downloadAllCurated(into libraryStore: LibraryStore) async {
        guard !curatedManifest.isEmpty, !isBatchDownloading else { return }

        isBatchDownloading = true
        batchProgress = (0, curatedManifest.count)
        defer {
            isBatchDownloading = false
            batchProgress = nil
        }

        var completed = 0
        for entry in curatedManifest {
            guard isBatchDownloading else { break }  // allow cancellation

            do {
                let result = try await fetchResult(for: entry)
                let _ = await importResult(result, into: libraryStore)
            } catch {
                // Skip items that can't be fetched; continue with remaining.
            }

            completed += 1
            batchProgress = (completed, curatedManifest.count)
        }
    }

    /// Cancels an ongoing batch download.
    public func cancelBatchDownload() {
        isBatchDownloading = false
        batchProgress = nil
    }

    /// Resolves a single result for a manifest entry by querying the archive.
    private func fetchResult(for entry: CuratedManifestEntry) async throws -> InternetArchiveSearchResult {
        let query = "identifier:\"\(entry.identifier)\""
        let page = try await client.searchAdvancedPage(query: query, rows: 1, page: 1, sort: .popularity)
        guard let result = page.results.first else {
            throw NSError(domain: "curated-lists", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "identifier not found: \(entry.identifier)"])
        }
        return result
    }

    private func runSearch(query: String, sort: CatalogSort) async {
        isSearching = true
        defer { isSearching = false }

        activeQuery = query
        activeSort = sort
        currentPage = 1

        do {
            let page = try await client.searchAdvancedPage(query: query, rows: pageSize, page: 1, sort: sort)
            numFound = page.numFound
            seenIdentifiers = []
            results = filteredResults(page.results, for: query)
                .filter { seenIdentifiers.insert($0.identifier).inserted }
            updateHasMore()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func filteredResults(
        _ results: [InternetArchiveSearchResult],
        for query: String
    ) -> [InternetArchiveSearchResult] {
        var filtered = results

        if query.localizedCaseInsensitiveContains("librivoxaudio") {
            filtered = filtered.filter(\.isStrictLibriVoxCatalogCandidate)
        }

        if let collectionID = activeCollectionID,
           let rules = CollectionRulesRegistry.rules(forCollectionID: collectionID) {
            filtered = filtered.filter { result in
                rules.allows(subjects: result.subjects, creator: result.authorLine, title: result.title)
            }
        }

        if filtered.isEmpty && !results.isEmpty && chainFetchCount < 3 {
            chainFetchCount += 1
            return results
        } else if !filtered.isEmpty {
            chainFetchCount = 0
        }

        return filtered
    }

    private func reloadForLanguageChange() {
        guard let base = baseQuery(from: activeQuery) else { return }
        let sort = activeSort
        Task { await runSearch(query: base + languageClause, sort: sort) }
    }

    /// Strips a previously-appended language clause so the base query can be
    /// re-decorated when the selection changes.
    private func baseQuery(from query: String?) -> String? {
        guard let query else { return nil }
        guard let range = query.range(of: " AND (language:") else { return query }
        return String(query[query.startIndex..<range.lowerBound])
    }

    private func resetResults() {
        results = []
        query = ""
        resetPaging()
    }

    private func resetPaging() {
        activeQuery = nil
        currentPage = 1
        numFound = 0
        hasMore = false
        seenIdentifiers = Set(results.map(\.identifier))
        curatedManifest = []
    }

    private func updateHasMore() {
        hasMore = results.count < numFound && !results.isEmpty
    }
}

public enum CatalogResultImporter {
    @MainActor
    public static func importResult(
        _ result: InternetArchiveSearchResult,
        into libraryStore: LibraryStore,
        using client: InternetArchiveCatalogClient
    ) async throws -> BookWithChapters? {
        do {
            let metadata = try await client.metadata(for: result.identifier)
            return await libraryStore.importInternetArchiveItem(metadata, sourceKind: result.sourceKind)
        } catch {
            // A seed identifier can go stale (archive.org returns an empty body).
            // Rather than dead-end the tap, search LibriVox for the same work by
            // title + creator and import the top live match. This keeps any future
            // stale bundled/recommended seed playable across all catalog entry points.
            if let recovered = await importBySearchFallback(for: result, into: libraryStore, using: client) {
                return recovered
            }
            throw error
        }
    }

    public static func importErrorMessage(
        for result: InternetArchiveSearchResult,
        underlying error: Error
    ) -> String {
        "Couldn't load '\(result.title)' (\(result.identifier)): \(error.localizedDescription)"
    }

    @MainActor
    private static func importBySearchFallback(
        for result: InternetArchiveSearchResult,
        into libraryStore: LibraryStore,
        using client: InternetArchiveCatalogClient
    ) async -> BookWithChapters? {
        let query = recoveryQuery(for: result)
        guard let query else { return nil }

        let candidates = (try? await client.searchAdvanced(query: query, rows: 5)) ?? []
        for candidate in candidates where candidate.identifier != result.identifier {
            guard let metadata = try? await client.metadata(for: candidate.identifier) else {
                continue
            }
            if let imported = await libraryStore.importInternetArchiveItem(metadata, sourceKind: candidate.sourceKind) {
                return imported
            }
        }
        return nil
    }

    private static func recoveryQuery(for result: InternetArchiveSearchResult) -> String? {
        let title = escapeSolrPhrase(result.title)
        guard !title.isEmpty else { return nil }

        var clauses = ["title:\"\(title)\""]
        if let creator = result.creators.first.map(escapeSolrPhrase), !creator.isEmpty {
            clauses.append("creator:\"\(creator)\"")
        }
        clauses.append(LibriVoxCatalogScope.query)
        return clauses.joined(separator: " AND ")
    }

    private static func escapeSolrPhrase(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
